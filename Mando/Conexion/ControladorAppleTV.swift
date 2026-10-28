import CryptoKit
import Foundation
import Network

/// Habla con un Apple TV por Companion, el protocolo que usan el Centro de
/// Control y la app Apple TV Remote del iPhone. Se empareja una vez con el
/// PIN de 4 dígitos de la tele; después, en cada conexión, los dos lados se
/// verifican con sus llaves y todo viaja cifrado.
///
/// Apple no lo documenta: los mensajes salen de pyatv, que lo reconstruyó.
actor ControladorAppleTV: Emparejable, ListaApps {
    nonisolated let reportes: AsyncStream<Reporte>
    private nonisolated let avisar: AsyncStream<Reporte>.Continuation

    private var destino: (host: String, puerto: UInt16)?
    private let cuenta: String

    private var conexion: NWConnection?
    private var canal: Canal?
    private var lectura: Task<Void, Never>?
    private var pendientes: [Int64: CheckedContinuation<OPACK, Error>] = [:]
    private var siguienteId: Int64 = 1
    private var alta: (conexion: NWConnection, sal: Data, b: Data, bufer: Data)?
    private var enCurso: Task<Void, Error>?
    private let buscarSiFalla: Bool
    /// Lo que se está reproduciendo llega por AirPlay, no por Companion.
    private var airplay: SesionAirPlay?
    private let puertoAirPlay: UInt16
    private var cuentaAirPlay: String { cuenta + "-AirPlay" }

    static let servicioBonjour = "_companion-link._tcp"

    init(host: String? = nil, puerto: UInt16 = 0, cuenta: String = "AppleTV", buscarSiFalla: Bool = true, puertoAirPlay: UInt16 = 7000) {
        self.puertoAirPlay = puertoAirPlay
        // Sin puerto no sirve la dirección: Companion cambia de puerto y sólo
        // el anuncio de Bonjour lo dice.
        destino = host.flatMap { puerto > 0 ? ($0, puerto) : nil }
        self.buscarSiFalla = buscarSiFalla
        self.cuenta = cuenta
        (reportes, avisar) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    // MARK: - Conectar

    func conectar() async throws {
        if let conexion, conexion.state == .ready { return }
        // Una sola conexión a la vez: la segunda espera a la primera.
        if let enCurso { return try await enCurso.value }
        let t = Task { try await abrir() }
        enCurso = t
        defer { enCurso = nil }
        try await t.value
    }

    private func abrir() async throws {
        soltar()
        let guardado = destino
        let destino = try await resolver()
        guard let credenciales = Credenciales.leer(cuenta), credenciales.emparejado else {
            // Sin credenciales no hay nada que verificar: si contesta, falta emparejar.
            try await comprobarQueContesta(destino)
            throw ErrorControl.porEmparejar
        }

        let nueva: NWConnection
        do {
            nueva = try await TCP.conectar(a: destino.host, puerto: destino.puerto, limite: .seconds(3))
        } catch where guardado != nil && buscarSiFalla {
            // Otra IP u otro puerto desde la última vez: se busca otra vez.
            self.destino = nil
            return try await abrir()
        } catch {
            throw ErrorControl.sinRespuesta("El Apple TV")
        }
        avisar.yield(.direccion(host: destino.host, puerto: destino.puerto))
        var bufer = Data()
        do {
            let verificacion = HAP.Verificacion()
            try await mandarTrama(.verificarInicio, .dic(["_pd": .datos(verificacion.m1), "_auTy": .entero(4)]), por: nueva)
            let m2 = try await tlv(de: nueva, &bufer)
            // Un error aquí es que el Apple TV ya no nos reconoce (alguien
            // quitó el emparejamiento en Ajustes): hay que emparejar de nuevo.
            guard m2[TLV8.error] == nil else { throw ErrorControl.porEmparejar }
            let r = try verificacion.responder(m2, credenciales: credenciales)
            try await mandarTrama(.verificarSiguiente, .dic(["_pd": .datos(r.m3)]), por: nueva)
            let m4 = try await tlv(de: nueva, &bufer)
            guard m4[TLV8.error] == nil else { throw ErrorControl.porEmparejar }
            canal = Canal(enviar: r.enviar, recibir: r.recibir)
        } catch ErrorControl.porEmparejar, ErrorControl.emparejamientoVencido {
            nueva.cancel()
            Credenciales.borrar(cuenta)
            throw ErrorControl.porEmparejar
        } catch {
            nueva.cancel()
            throw ErrorControl.sinRespuesta("El Apple TV")
        }

        conexion = nueva
        leer(nueva, bufer: bufer)
        try await presentarse(credenciales)
        Task { await abrirReproduccion() }
    }

    // MARK: - Lo que se reproduce (AirPlay)

    /// Intenta con las llaves de AirPlay y, si no hay, con las de Companion:
    /// si la tele las acepta, no hace falta un segundo PIN.
    private func abrirReproduccion() async {
        guard let destino else { return }
        if let airplay, await airplay.abierta { return }
        // Primero las de AirPlay y luego las de Companion: si el Apple TV
        // olvidó un emparejamiento, el otro todavía puede servir.
        let candidatas = [Credenciales.leer(cuentaAirPlay), Credenciales.leer(cuenta)].compactMap { $0 }.filter(\.emparejado)
        guard !candidatas.isEmpty else { return }
        let sesion = sesionAirPlay(destino.host)
        for credenciales in candidatas {
            do {
                try await sesion.abrir(credenciales: credenciales)
                avisar.yield(.reproduccionPorEmparejar(false))
                return
            } catch ErrorControl.porEmparejar {
                continue
            } catch {
                // Sin AirPlay el control sigue funcionando; sólo no se ve qué suena.
                return
            }
        }
        avisar.yield(.reproduccionPorEmparejar(true))
    }

    private func sesionAirPlay(_ host: String) -> SesionAirPlay {
        if let airplay { return airplay }
        let avisar = self.avisar
        let nueva = SesionAirPlay(host: host, puerto: puertoAirPlay, cuenta: cuentaAirPlay) { r, app in
            avisar.yield(.reproduciendo(r))
            if let app { avisar.yield(.appPorId(app)) }
        }
        airplay = nueva
        return nueva
    }

    func pedirCodigoReproduccion() async throws {
        let destino = try await resolver()
        try await sesionAirPlay(destino.host).pedirCodigo()
    }

    func confirmarReproduccion(codigo: String) async throws {
        guard let destino else { throw ErrorControl.emparejamientoVencido }
        try await sesionAirPlay(destino.host).confirmar(codigo: codigo)
        await abrirReproduccion()
    }

    /// Lo que la app oficial manda al conectar. Sin la sesión de
    /// «tvremoteservices» el Apple TV ignora las teclas.
    private func presentarse(_ c: Credenciales) async throws {
        _ = try await pedir("_systemInfo", .dic([
            "_bf": .entero(0), "_cf": .entero(512), "_clFl": .entero(128),
            "_i": .texto("cafecafecafe"), "_idsID": .texto(c.clienteId),
            "_pubID": .texto("FF:70:79:61:74:76"), "_sf": .entero(256), "_sv": .texto("170.18"),
            "model": .texto("iPhone"), "name": .texto("Mando"),
        ]))
        _ = try await pedir("_sessionStart", .dic([
            "_srvT": .texto("com.apple.tvremoteservices"),
            "_sid": .entero(Int64(UInt32.random(in: 1...UInt32.max))),
        ]))
        // Los avisos de estado llegan solos cuando el Apple TV se duerme o
        // despierta. Algunos modelos (el Apple TV HD con que se probó) nunca
        // contestan la pregunta directa, así que la suscripción va primero y
        // la pregunta no detiene nada si no hay respuesta.
        try await avisarEvento("_interest", .dic(["_regEvents": .lista([.texto("SystemStatus")])]))
        Task { [weak self] in
            if let estado = try? await self?.pedir("FetchAttentionState", .dic([:]))["state"]?.entero {
                await self?.reportarEstado(estado)
            }
        }
    }

    /// 1 dormido, 2 protector de pantalla, 3 despierto, 4 inactivo.
    private func reportarEstado(_ estado: Int64) {
        avisar.yield(.encendido(estado >= 2))
    }

    /// Un mensaje sin respuesta (`_t` 1): suscripciones y avisos.
    private func avisarEvento(_ nombre: String, _ contenido: OPACK) async throws {
        guard let conexion, var canal else { throw ErrorControl.sinRespuesta("El Apple TV") }
        let mensaje = OPACK.dic(["_i": .texto(nombre), "_x": .entero(siguienteId), "_t": .entero(1), "_c": contenido])
        siguienteId += 1
        let datos = try canal.cifrar(Trama.Tipo.cifrada, mensaje.empacado)
        self.canal = canal
        conexion.send(content: datos, completion: .idempotent)
    }

    func mandar(_ orden: Orden) async throws {
        try await conectar()
        switch orden {
        case .abrirApp(let app):
            _ = try await pedir("_launchApp", .dic(["_bundleID": .texto(app.id)]))
            avisar.yield(.app(app.nombre))
        case .escribir(let texto):
            try await escribir(texto)
        case .encender(let si):
            try await tecla(si ? 13 : 12)
            avisar.yield(.encendido(si))
        default:
            guard let codigo = ControladorAppleTV.tecla(para: orden) else {
                throw ErrorControl.noSoportada(orden, .appleTV)
            }
            try await tecla(codigo)
        }
    }

    /// Escribe en el campo de texto activo del Apple TV, reemplazando lo que
    /// tenga. Sin un campo activo (la búsqueda abierta), `_tiStart` no trae
    /// sesión y no hay dónde escribir.
    private func escribir(_ texto: String) async throws {
        let inicio = try await pedir("_tiStart", .dic([:]))
        guard let archivo = inicio["_tiD"]?.datos, let sesion = TextoCompanion.sesion(en: archivo) else {
            throw ErrorControl.sinCampoDeTexto
        }
        try await avisarEvento("_tiC", .dic(["_tiV": .entero(1), "_tiD": .datos(try TextoCompanion.borrar(sesion: sesion))]))
        if !texto.isEmpty {
            try await avisarEvento("_tiC", .dic(["_tiV": .entero(1), "_tiD": .datos(try TextoCompanion.insertar(texto, sesion: sesion))]))
        }
        _ = try? await pedir("_tiStop", .dic([:]))
    }

    /// Apretar y soltar, como un dedo en el control.
    private func tecla(_ codigo: Int64) async throws {
        for estado: Int64 in [1, 2] {
            _ = try await pedir("_hidC", .dic(["_hBtS": .entero(estado), "_hidC": .entero(codigo)]))
        }
    }

    /// Las apps que el Apple TV puede abrir, con el nombre que muestra.
    func appsInstaladas() async throws -> [Aplicacion] {
        try await conectar()
        let lista = try await pedir("FetchLaunchableApplicationsEvent", .dic([:]))
        guard case .diccionario(let pares) = lista else { return [] }
        return pares.compactMap { par in
            guard let id = par.0.texto, let nombre = par.1.texto else { return nil }
            return Aplicacion(id: id, nombre: nombre)
        }
        .sorted { $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending }
    }

    // MARK: - Emparejar

    func pedirCodigo() async throws {
        alta?.conexion.cancel()
        alta = nil
        let destino = try await resolver()
        let c: NWConnection
        do {
            c = try await TCP.conectar(a: destino.host, puerto: destino.puerto, limite: .seconds(3))
        } catch {
            throw ErrorControl.sinRespuesta("El Apple TV")
        }
        var bufer = Data()
        do {
            try await mandarTrama(.altaInicio, .dic(["_pd": .datos(HAP.altaM1()), "_pwTy": .entero(1)]), por: c)
            let m2 = try await tlv(de: c, &bufer)
            guard m2[TLV8.error] == nil, let sal = m2[TLV8.sal], let b = m2[TLV8.llavePublica] else {
                // El Apple TV rechaza altas seguidas por un rato: hay que esperar.
                throw ErrorControl.pendiente("El Apple TV no quiso mostrar el código. Espera un minuto y vuelve a pedirlo.")
            }
            alta = (c, sal, b, bufer)
        } catch let error as ErrorControl {
            c.cancel()
            throw error
        } catch {
            c.cancel()
            throw ErrorControl.sinRespuesta("El Apple TV")
        }
    }

    func confirmar(codigo: String) async throws {
        guard var alta else { throw ErrorControl.emparejamientoVencido }
        self.alta = nil
        defer { alta.conexion.cancel() }
        let pin = codigo.filter(\.isNumber)
        guard pin.count == 4,
              let srp = SRPCliente().calcular(sal: alta.sal, publicaServidor: alta.b, pin: pin) else {
            throw ErrorControl.codigoIncorrecto
        }
        // Se conserva el identificador si ya existía, para que el Apple TV
        // no acumule un «Mando» nuevo en su lista cada vez que se empareja.
        var credenciales = Credenciales.leer(cuenta) ?? .nuevas()
        do {
            try await mandarTrama(.altaSiguiente, .dic(["_pd": .datos(HAP.altaM3(srp))]), por: alta.conexion)
            let m4 = try await tlv(de: alta.conexion, &alta.bufer)
            guard m4[TLV8.error] == nil, m4[TLV8.prueba] == srp.pruebaEsperada else {
                throw ErrorControl.codigoIncorrecto
            }
            let m5 = try HAP.altaM5(llaveSRP: srp.llave, credenciales: credenciales, extra: ControladorAppleTV.info)
            try await mandarTrama(.altaSiguiente, .dic(["_pd": .datos(m5)]), por: alta.conexion)
            let m6 = try await tlv(de: alta.conexion, &alta.bufer)
            guard m6[TLV8.error] == nil else { throw ErrorControl.emparejamientoRechazado }
            let suya = try HAP.altaM6(m6, llaveSRP: srp.llave)
            credenciales.teleId = suya.id
            credenciales.llaveTele = suya.llave
            credenciales.guardar(cuenta)
        } catch let error as ErrorControl {
            throw error
        } catch {
            throw ErrorControl.sinRespuesta("El Apple TV")
        }
        try await conectar()
    }

    // MARK: - Red

    private func resolver() async throws -> (host: String, puerto: UInt16) {
        if let destino { return destino }
        guard let encontrado = await BuscadorBonjour.primero(
            ControladorAppleTV.servicioBonjour, limite: .seconds(4), acepta: ControladorAppleTV.esAppleTV
        ) else {
            throw ErrorControl.appleTVNoEncontrado
        }
        destino = encontrado
        return encontrado
    }

    private func comprobarQueContesta(_ d: (host: String, puerto: UInt16)) async throws {
        guard let c = try? await TCP.conectar(a: d.host, puerto: d.puerto, limite: .seconds(3)) else {
            throw ErrorControl.sinRespuesta("El Apple TV")
        }
        c.cancel()
    }

    /// Manda una petición cifrada y espera su respuesta (la que trae el mismo `_x`).
    private func pedir(_ nombre: String, _ contenido: OPACK) async throws -> OPACK {
        guard let conexion, var canal else { throw ErrorControl.sinRespuesta("El Apple TV") }
        let id = siguienteId
        siguienteId += 1
        let mensaje = OPACK.dic(["_i": .texto(nombre), "_x": .entero(id), "_t": .entero(2), "_c": contenido])
        let datos = try canal.cifrar(Trama.Tipo.cifrada, mensaje.empacado)
        self.canal = canal
        // La espera se registra antes de mandar: el Apple TV contesta tan
        // rápido que la respuesta podía llegar antes y perderse.
        // Y se manda aquí mismo, sin pasar por una tarea: el contador del
        // cifrado exige que las tramas salgan en el orden en que se cifraron.
        let respuesta = try await withCheckedThrowingContinuation { c in
            pendientes[id] = c
            conexion.send(content: datos, completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                Task { await self?.soltar() }
            })
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                await self?.vencer(id)
            }
        }
        return respuesta["_c"] ?? .dic([:])
    }

    private func vencer(_ id: Int64) {
        pendientes.removeValue(forKey: id)?.resume(throwing: ErrorControl.sinRespuesta("El Apple TV"))
    }

    private func leer(_ c: NWConnection, bufer inicial: Data) {
        lectura = Task {
            var bufer = inicial
            while !Task.isCancelled {
                guard let datos = try? await TCP.recibir(de: c) else { break }
                bufer.append(datos)
                while let trama = Trama.extraer(de: &bufer) {
                    recibir(trama)
                }
            }
            soltar()
        }
    }

    private func recibir(_ trama: Trama) {
        guard trama.tipo == Trama.Tipo.cifrada, var canal,
              let claro = try? canal.descifrar(trama),
              let mensaje = try? OPACK.desempacar(claro) else { return }
        self.canal = canal
        if mensaje["_t"]?.entero == 3, let id = mensaje["_x"]?.entero {
            pendientes.removeValue(forKey: id)?.resume(returning: mensaje)
        } else if mensaje["_i"]?.texto == "SystemStatus", let estado = mensaje["_c"]?["state"]?.entero {
            reportarEstado(estado)
        }
    }

    private func soltar() {
        if let airplay { Task { await airplay.cerrar() } }
        lectura?.cancel()
        lectura = nil
        conexion?.cancel()
        conexion = nil
        canal = nil
        for (_, c) in pendientes { c.resume(throwing: ErrorControl.sinRespuesta("El Apple TV")) }
        pendientes.removeAll()
    }

    private func mandarTrama(_ tipo: UInt8, _ contenido: OPACK, por c: NWConnection) async throws {
        try await TCP.mandar(Trama.armar(tipo, contenido.empacado), por: c)
    }

    /// La siguiente trama de emparejamiento, ya convertida de OPACK a TLV8.
    private func tlv(de c: NWConnection, _ bufer: inout Data) async throws -> [UInt8: Data] {
        let fin = ContinuousClock.now + .seconds(5)
        while true {
            if let trama = Trama.extraer(de: &bufer) {
                guard let pd = try OPACK.desempacar(trama.datos)["_pd"]?.datos else {
                    throw ErrorControl.emparejamientoRechazado
                }
                return TLV8.leer(pd)
            }
            guard ContinuousClock.now < fin,
                  let datos = try await TCP.recibir(de: c, limite: fin - ContinuousClock.now) else {
                throw TCP.SinRespuesta()
            }
            bufer.append(datos)
        }
    }

    /// Macs, iPhones y iPads también anuncian Companion. El modelo viene en
    /// el anuncio («rpMd=AppleTV5,3»): sólo ése sirve de control.
    static func esAppleTV(_ txt: [String: String]) -> Bool {
        txt["rpMd"]?.hasPrefix("AppleTV") == true
    }

    // MARK: - Tablas

    /// Códigos HID de Companion.
    static func tecla(para orden: Orden) -> Int64? {
        switch orden {
        case .mover(.arriba): 1
        case .mover(.abajo): 2
        case .mover(.izquierda): 3
        case .mover(.derecha): 4
        case .atras: 5
        case .elegir: 6
        case .inicio: 7
        case .subirVolumen: 8
        case .bajarVolumen: 9
        case .playPausa: 14
        default: nil
        }
    }

    /// Cómo aparece el teléfono en la lista de aparatos del Apple TV.
    static let info = OPACK.dic([
        "name": .texto("Mando"),
        "model": .texto("iPhone"),
        "mac": .datos(Data((0..<6).map { _ in UInt8.random(in: 0...255) })),
        "altIRK": .datos(Data((0..<16).map { _ in UInt8.random(in: 0...255) })),
        "accountID": .texto(UUID().uuidString),
        "btAddr": .texto("FF:DD:99:66:22:11"),
    ]).empacado
}

/// Una trama de Companion: tipo, largo en 3 bytes y contenido.
nonisolated struct Trama {
    enum Tipo {
        static let altaInicio: UInt8 = 0x03
        static let altaSiguiente: UInt8 = 0x04
        static let verificarInicio: UInt8 = 0x05
        static let verificarSiguiente: UInt8 = 0x06
        static let cifrada: UInt8 = 0x08
    }

    let tipo: UInt8
    let encabezado: Data
    let datos: Data

    static func encabezado(_ tipo: UInt8, _ largo: Int) -> Data {
        Data([tipo, UInt8(largo >> 16 & 0xFF), UInt8(largo >> 8 & 0xFF), UInt8(largo & 0xFF)])
    }

    static func armar(_ tipo: UInt8, _ datos: Data) -> Data {
        encabezado(tipo, datos.count) + datos
    }

    static func extraer(de bufer: inout Data) -> Trama? {
        guard bufer.count >= 4 else { return nil }
        let i = bufer.startIndex
        let largo = Int(bufer[i + 1]) << 16 | Int(bufer[i + 2]) << 8 | Int(bufer[i + 3])
        guard bufer.count >= 4 + largo else { return nil }
        let t = Trama(tipo: bufer[i], encabezado: bufer.subdata(in: i..<(i + 4)), datos: bufer.subdata(in: (i + 4)..<(i + 4 + largo)))
        bufer.removeSubrange(i..<(i + 4 + largo))
        return t
    }
}

private extension UInt8 {
    static let altaInicio = Trama.Tipo.altaInicio
    static let altaSiguiente = Trama.Tipo.altaSiguiente
    static let verificarInicio = Trama.Tipo.verificarInicio
    static let verificarSiguiente = Trama.Tipo.verificarSiguiente
}

/// El canal cifrado después de verificar: ChaCha20-Poly1305 con un contador
/// por sentido como nonce y el encabezado de la trama como dato autenticado.
nonisolated struct Canal {
    let enviar: SymmetricKey
    let recibir: SymmetricKey
    private var contadorEnvio: UInt64 = 0
    private var contadorRecibo: UInt64 = 0

    init(enviar: SymmetricKey, recibir: SymmetricKey) {
        self.enviar = enviar
        self.recibir = recibir
    }

    mutating func cifrar(_ tipo: UInt8, _ claro: Data) throws -> Data {
        let encabezado = Trama.encabezado(tipo, claro.count + 16)
        let caja = try ChaChaPoly.seal(claro, using: enviar, nonce: Canal.nonce(contadorEnvio), authenticating: encabezado)
        contadorEnvio += 1
        return encabezado + caja.ciphertext + caja.tag
    }

    mutating func descifrar(_ t: Trama) throws -> Data {
        let caja = try ChaChaPoly.SealedBox(nonce: Canal.nonce(contadorRecibo), ciphertext: t.datos.dropLast(16), tag: t.datos.suffix(16))
        let claro = try ChaChaPoly.open(caja, using: recibir, authenticating: t.encabezado)
        contadorRecibo += 1
        return claro
    }

    static func nonce(_ n: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: withUnsafeBytes(of: n.littleEndian, Array.init) + [0, 0, 0, 0])
    }
}
