import Foundation
import Network
import Security

/// Los aparatos que se emparejan con un código en pantalla antes de obedecer.
nonisolated protocol Emparejable: Controlador {
    /// Abre el emparejamiento: la tele muestra un código de 6 caracteres.
    func pedirCodigo() async throws
    func confirmar(codigo: String) async throws
}

/// Habla con un Google TV (o cualquier Android TV) por el protocolo del
/// control remoto v2. La primera vez hay que emparejar; después la tele
/// reconoce el certificado de este teléfono y conecta sola.
actor ControladorGoogleTV: Emparejable {
    nonisolated let reportes: AsyncStream<Reporte>
    private nonisolated let avisar: AsyncStream<Reporte>.Continuation

    private var host: String?
    private let puertoControl: UInt16
    private let puertoEmparejar: UInt16
    private let nombreCertificado: String

    private var conexion: NWConnection?
    private var lectura: Task<Void, Never>?
    private var emparejando: (conexion: NWConnection, llaveTele: SecKey)?
    // Google TV sólo sabe «alternar» encendido y silencio: hay que recordar
    // el estado que reportó para no apagar cuando se pidió prender.
    private var encendida: Bool?
    private var callada: Bool?
    /// Los contadores del último campo de texto que abrió la tele. Sin ellos
    /// la tele ignora lo que se escriba.
    private var campoAbierto: (ime: UInt64, campo: UInt64)?
    /// Lo último que se escribió tecla por tecla, para mandar sólo la
    /// diferencia. Se olvida al rato: la siguiente búsqueda empieza vacía.
    private var tecleado = (texto: "", cuando: ContinuousClock.now)
    private var enCurso: Task<Void, Error>?
    private let buscarSiFalla: Bool

    init(
        host: String? = nil,
        puertoControl: UInt16 = AndroidTV.puertoControl,
        puertoEmparejar: UInt16 = AndroidTV.puertoEmparejar,
        nombreCertificado: String = "Mando",
        buscarSiFalla: Bool = true
    ) {
        self.buscarSiFalla = buscarSiFalla
        self.host = host
        self.puertoControl = puertoControl
        self.puertoEmparejar = puertoEmparejar
        self.nombreCertificado = nombreCertificado
        (reportes, avisar) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    func conectar() async throws {
        if let conexion, conexion.state == .ready { return }
        // Una sola conexión a la vez: la segunda espera a la primera.
        if let enCurso { return try await enCurso.value }
        let t = Task {
            do {
                try await abrir()
            } catch ErrorControl.sinRespuesta(let quien) {
                // La dirección guardada ya no contesta: se busca otra vez.
                guard dejarDeUsarDireccionGuardada() else { throw ErrorControl.sinRespuesta(quien) }
                try await abrir()
            }
        }
        enCurso = t
        defer { enCurso = nil }
        try await t.value
    }

    /// Si había una dirección guardada y se puede buscar, la olvida y avisa
    /// que vale la pena intentar de nuevo.
    private func dejarDeUsarDireccionGuardada() -> Bool {
        guard buscarSiFalla, host != nil, !buscada else { return false }
        host = nil
        return true
    }

    private func abrir() async throws {
        soltar()
        let host = try await resolverHost()
        let identidad = try Certificado.identidad(nombre: nombreCertificado)
        let nueva: NWConnection
        do {
            nueva = try await TCP.conectar(
                a: host, puerto: puertoControl, limite: .seconds(3),
                parametros: TLS.parametros(identidad: identidad, llaveDelOtro: Caja())
            )
        } catch {
            throw await motivoDeFalla(host)
        }
        // Con TLS 1.3 el teléfono da el saludo por bueno antes de que la tele
        // revise nuestro certificado. Si no lo conoce, corta justo después; la
        // señal de que sí nos aceptó es su primer mensaje.
        var bufer = Data()
        guard let primero = try? await siguiente(de: nueva, bufer: &bufer, limite: .seconds(3)) else {
            nueva.cancel()
            throw await motivoDeFalla(host)
        }
        conexion = nueva
        avisar.yield(.direccion(host: host, puerto: puertoControl))
        try await atender(primero, en: nueva)
        leer(nueva, bufer: bufer)
    }

    func mandar(_ orden: Orden) async throws {
        let datos: Data
        switch orden {
        case .encender(let si) where encendida == si:
            return
        case .silencio(let si) where callada == si:
            return
        case .abrirApp(let app):
            datos = AndroidTV.abrir(app.id)
        case .escribir(let texto):
            guard let campo = campoAbierto else {
                // Algunas apps (YouTube) no avisan del campo: se teclea.
                try await teclear(texto)
                return
            }
            datos = AndroidTV.escribir(texto, ime: campo.ime, campo: campo.campo)
        default:
            guard let codigo = AndroidTV.tecla(para: orden) else { throw ErrorControl.noSoportada(orden, .googleTV) }
            datos = AndroidTV.tecla(codigo)
        }
        try await conectar()
        guard let conexion else { throw ErrorControl.sinRespuesta("Google TV") }
        do {
            try await TCP.mandar(Marco.envolver(datos), por: conexion)
        } catch {
            soltar()
            throw ErrorControl.sinRespuesta("Google TV")
        }
    }

    /// Escribe como si fuera el control: borra lo que sobra de lo tecleado
    /// antes y teclea lo que falta. Sólo letras sin acento, números y lo
    /// básico: es lo que tiene el teclado de un control.
    private func teclear(_ texto: String) async throws {
        if ContinuousClock.now - tecleado.cuando > .seconds(30) { tecleado.texto = "" }
        let nuevo = AndroidTV.paraTeclas(texto)
        let comun = zip(tecleado.texto, nuevo).prefix { $0 == $1 }.count
        var teclas = Array(repeating: AndroidTV.teclaBorrar, count: tecleado.texto.count - comun)
        teclas += nuevo.dropFirst(comun).compactMap(AndroidTV.tecla(para:))
        try await conectar()
        guard let conexion else { throw ErrorControl.sinRespuesta("Google TV") }
        for codigo in teclas {
            try await TCP.mandar(Marco.envolver(AndroidTV.tecla(codigo)), por: conexion)
        }
        tecleado = (nuevo, .now)
    }

    // MARK: - Emparejar

    func pedirCodigo() async throws {
        cerrarEmparejamiento()
        let host = try await resolverHost()
        let identidad = try Certificado.identidad(nombre: nombreCertificado)
        let llave = Caja<SecKey>()
        let c: NWConnection
        do {
            c = try await TCP.conectar(
                a: host, puerto: puertoEmparejar, limite: .seconds(4),
                parametros: TLS.parametros(identidad: identidad, llaveDelOtro: llave)
            )
        } catch {
            throw ErrorControl.sinRespuesta("Google TV")
        }
        guard let llaveTele = llave.valor else {
            c.cancel()
            throw ErrorControl.sinRespuesta("Google TV")
        }
        var bufer = Data()
        do {
            // Saludo, opciones y configuración: después de la tercera
            // respuesta la tele muestra el código.
            for paso in [AndroidTV.Emparejar.solicitud(cliente: "Mando"),
                         AndroidTV.Emparejar.opciones(),
                         AndroidTV.Emparejar.configuracion()] {
                try await TCP.mandar(Marco.envolver(paso), por: c)
                let respuesta = try await siguiente(de: c, bufer: &bufer, limite: .seconds(5))
                guard AndroidTV.Emparejar.leer(respuesta).estado == AndroidTV.Emparejar.ok else {
                    throw ErrorControl.emparejamientoRechazado
                }
            }
        } catch let error as ErrorControl {
            c.cancel()
            throw error
        } catch {
            c.cancel()
            throw ErrorControl.sinRespuesta("Google TV")
        }
        emparejando = (c, llaveTele)
    }

    func confirmar(codigo: String) async throws {
        guard let (c, llaveTele) = emparejando else { throw ErrorControl.emparejamientoVencido }
        let identidad = try Certificado.identidad(nombre: nombreCertificado)
        guard let nuestra = Certificado.llavePublica(de: identidad).flatMap(Certificado.numeros),
              let suya = Certificado.numeros(de: llaveTele) else {
            throw ErrorControl.emparejamientoRechazado
        }
        guard let hash = AndroidTV.Emparejar.hash(codigo: codigo, cliente: nuestra, tele: suya) else {
            // No se cierra: la tele sigue mostrando el código y se puede corregir.
            throw ErrorControl.codigoIncorrecto
        }
        var bufer = Data()
        do {
            try await TCP.mandar(Marco.envolver(AndroidTV.Emparejar.secreto(hash)), por: c)
            let respuesta = try await siguiente(de: c, bufer: &bufer, limite: .seconds(5))
            let leido = AndroidTV.Emparejar.leer(respuesta)
            guard leido.estado == AndroidTV.Emparejar.ok, leido.campos.contains(41) else {
                cerrarEmparejamiento()
                throw ErrorControl.codigoIncorrecto
            }
        } catch let error as ErrorControl {
            throw error
        } catch {
            cerrarEmparejamiento()
            throw ErrorControl.sinRespuesta("Google TV")
        }
        cerrarEmparejamiento()
        try await conectar()
    }

    // MARK: - Privado

    /// Si la dirección ya salió de Bonjour en esta sesión, no tiene caso
    /// volver a buscar: el aparato simplemente no contesta.
    private var buscada = false

    private func resolverHost() async throws -> String {
        if let host { return host }
        buscada = true
        guard let encontrado = await BuscadorBonjour.primero(AndroidTV.servicioBonjour, limite: .seconds(4)) else {
            throw ErrorControl.googleTVNoEncontrado
        }
        host = encontrado.host
        return encontrado.host
    }

    /// Distingue «no contesta» de «contesta pero no nos conoce»: lo segundo se
    /// arregla emparejando, lo primero revisando la red.
    private func motivoDeFalla(_ host: String) async -> ErrorControl {
        if let c = try? await TCP.conectar(a: host, puerto: puertoEmparejar, limite: .seconds(2)) {
            c.cancel()
            return .porEmparejar
        }
        return .sinRespuesta("Google TV")
    }

    private func leer(_ c: NWConnection, bufer inicial: Data) {
        lectura = Task {
            var bufer = inicial
            while !Task.isCancelled {
                guard let datos = try? await TCP.recibir(de: c) else { break }
                bufer.append(datos)
                for mensaje in Marco.extraer(de: &bufer) {
                    try? await atender(mensaje, en: c)
                }
            }
            soltar()
        }
    }

    private func atender(_ mensaje: Data, en c: NWConnection) async throws {
        switch AndroidTV.leer(mensaje) {
        case .configurar:
            try await TCP.mandar(Marco.envolver(AndroidTV.configurar(modelo: "iPhone")), por: c)
        case .activar:
            try await TCP.mandar(Marco.envolver(AndroidTV.activar()), por: c)
        case .ping(let v):
            // Sin respuesta al ping la tele corta a los pocos segundos.
            try await TCP.mandar(Marco.envolver(AndroidTV.pong(v)), por: c)
        case .encendido(let si):
            encendida = si
            avisar.yield(.encendido(si))
        case .volumen(let nivel, let maximo, let silencio):
            callada = silencio
            // La app piensa en una escala de 0 a 80 como el receptor; la tele
            // reporta sobre su propio máximo (casi siempre 100).
            avisar.yield(.volumen(maximo > 0 ? nivel * 80 / maximo : nivel))
            avisar.yield(.silencio(silencio))
        case .campoDeTexto(let ime, let campo):
            // El aviso de «mostrar teclado» no trae el contador de IME: se
            // conserva el último que llegó.
            campoAbierto = (ime == 0 ? campoAbierto?.ime ?? 0 : ime, campo)
        case .app(let paquete):
            avisar.yield(.app(AndroidTV.nombresDePaquete[paquete] ?? paquete))
        case .otro:
            break
        }
    }

    private func siguiente(de c: NWConnection, bufer: inout Data, limite: Duration) async throws -> Data {
        let fin = ContinuousClock.now + limite
        while true {
            if let mensaje = Marco.extraer(de: &bufer).first { return mensaje }
            guard ContinuousClock.now < fin,
                  let datos = try await TCP.recibir(de: c, limite: fin - ContinuousClock.now) else {
                throw TCP.SinRespuesta()
            }
            bufer.append(datos)
        }
    }

    private func cerrarEmparejamiento() {
        emparejando?.conexion.cancel()
        emparejando = nil
    }

    private func soltar() {
        lectura?.cancel()
        lectura = nil
        conexion?.cancel()
        conexion = nil
    }
}
