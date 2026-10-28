import Foundation
import Network

/// Lo que se está reproduciendo en el Apple TV, por AirPlay 2: el mismo canal
/// que usan la pantalla de bloqueo y el Centro de Control del iPhone. Son tres
/// conexiones cifradas con llaves distintas, todas salidas de la verificación:
/// control (RTSP), avisos (la tele pregunta y se le contesta 200) y datos (el
/// MRP con lo que suena).
///
/// El orden y los valores salen de pyatv (`protocols/airplay/ap2_session.py`
/// y `channels.py`).
actor SesionAirPlay {
    private let host: String
    private let puerto: UInt16
    private let cuenta: String
    private let alCambiar: @Sendable (Reproduciendo?, String?) -> Void

    private var control: Tubo?
    private var avisos: Tubo?
    private var datos: Tubo?
    private var tareas: [Task<Void, Never>] = []
    private var cseq = 0
    private var uri = ""
    private let dacp = String(format: "%016llX", UInt64.random(in: 0...UInt64.max))
    private let remoto = String(UInt32.random(in: 0...UInt32.max))
    private var estado = EstadoMRP()
    private var ultimoAviso: Reproduciendo??
    private var alta: (tubo: Tubo, sal: Data, b: Data)?

    static let agente = "AirPlay/550.10"

    init(host: String, puerto: UInt16 = 7000, cuenta: String, alCambiar: @escaping @Sendable (Reproduciendo?, String?) -> Void) {
        self.host = host
        self.puerto = puerto
        self.cuenta = cuenta
        self.alCambiar = alCambiar
    }

    var abierta: Bool { control != nil }

    // MARK: - Emparejar (una vez, con el PIN de la tele)

    func pedirCodigo() async throws {
        let tubo = try await conectar(puerto)
        _ = try await pedirHTTP(tubo, "/pair-pin-start", cuerpo: Data())
        let m2 = TLV8.leer(try await pedirHTTP(tubo, "/pair-setup", cuerpo: HAP.altaM1()))
        guard m2[TLV8.error] == nil, let sal = m2[TLV8.sal], let b = m2[TLV8.llavePublica] else {
            await tubo.cerrar()
            throw ErrorControl.pendiente("El Apple TV no quiso mostrar el código. Espera un minuto y vuelve a pedirlo.")
        }
        alta = (tubo, sal, b)
    }

    func confirmar(codigo: String) async throws {
        guard let alta else { throw ErrorControl.emparejamientoVencido }
        self.alta = nil
        defer { Task { await alta.tubo.cerrar() } }
        let pin = codigo.filter(\.isNumber)
        guard pin.count == 4, let srp = SRPCliente().calcular(sal: alta.sal, publicaServidor: alta.b, pin: pin) else {
            throw ErrorControl.codigoIncorrecto
        }
        var credenciales = Credenciales.leer(cuenta) ?? .nuevas()
        let m4 = TLV8.leer(try await pedirHTTP(alta.tubo, "/pair-setup", cuerpo: HAP.altaM3(srp)))
        guard m4[TLV8.error] == nil, m4[TLV8.prueba] == srp.pruebaEsperada else { throw ErrorControl.codigoIncorrecto }
        let nombre = OPACK.dic(["name": .texto("Mando")]).empacado
        let m5 = try HAP.altaM5(llaveSRP: srp.llave, credenciales: credenciales, extra: nombre)
        let m6 = TLV8.leer(try await pedirHTTP(alta.tubo, "/pair-setup", cuerpo: m5))
        guard m6[TLV8.error] == nil else { throw ErrorControl.emparejamientoRechazado }
        let suya = try HAP.altaM6(m6, llaveSRP: srp.llave)
        credenciales.teleId = suya.id
        credenciales.llaveTele = suya.llave
        credenciales.guardar(cuenta)
    }

    // MARK: - Abrir

    /// Verifica con las credenciales y abre las tres conexiones. Si la tele
    /// no reconoce las credenciales, `ErrorControl.porEmparejar`.
    func abrir(credenciales: Credenciales) async throws {
        if control != nil { return }
        let tubo = try await conectar(puerto)

        // Verificación por HTTP, sin cifrar todavía.
        let verificacion = HAP.Verificacion()
        let m2 = TLV8.leer(try await pedirHTTP(tubo, "/pair-verify", cuerpo: verificacion.m1))
        guard m2[TLV8.error] == nil else { throw ErrorControl.porEmparejar }
        let r: (m3: Data, compartido: Data)
        do {
            let v = try verificacion.responder(m2, credenciales: credenciales)
            r = (v.m3, v.compartido)
        } catch {
            await tubo.cerrar()
            throw ErrorControl.porEmparejar
        }
        let m4 = TLV8.leer(try await pedirHTTP(tubo, "/pair-verify", cuerpo: r.m3))
        guard m4[TLV8.error] == nil else {
            await tubo.cerrar()
            throw ErrorControl.porEmparejar
        }
        await tubo.cifrar(con: CanalHAP(
            secreto: r.compartido, sal: "Control-Salt",
            infoEnviar: "Control-Write-Encryption-Key", infoRecibir: "Control-Read-Encryption-Key"
        ))
        control = tubo
        let local = Self.ipLocal(tubo.conexion) ?? "127.0.0.1"
        uri = "rtsp://\(local)/\(UInt32.random(in: 0...UInt32.max))"

        do {
            // 1. Sesión de sólo control remoto; la tele dice dónde manda avisos.
            let sesion = try await rtsp("SETUP", cuerpo: [
                "isRemoteControlOnly": true, "osName": "iPhone OS", "sourceVersion": "550.10",
                "timingProtocol": "None", "model": "iPhone10,6", "deviceID": "FF:70:79:61:74:76",
                "osVersion": "14.7.1", "osBuildVersion": "18G82", "macAddress": "02:70:79:61:74:76",
                "sessionUUID": UUID().uuidString, "name": "Mando",
            ])
            guard let puertoAvisos = (sesion.plist?["eventPort"] as? NSNumber)?.uint16Value else {
                throw ErrorControl.sinRespuesta("El Apple TV")
            }
            let avisos = try await conectar(puertoAvisos)
            // En los avisos las llaves van al revés: la tele es la que pregunta.
            await avisos.cifrar(con: CanalHAP(
                secreto: r.compartido, sal: "Events-Salt",
                infoEnviar: "Events-Read-Encryption-Key", infoRecibir: "Events-Write-Encryption-Key"
            ))
            self.avisos = avisos
            tareas.append(Task { await self.contestarAvisos(avisos) })

            _ = try await rtsp("RECORD")

            // 2. El canal de datos, con su semilla para las llaves.
            let semilla = UInt64.random(in: 0...UInt64(Int64.max))
            let flujo = try await rtsp("SETUP", cuerpo: ["streams": [[
                "controlType": 2, "channelID": UUID().uuidString, "seed": NSNumber(value: semilla),
                "clientUUID": UUID().uuidString, "type": 130, "wantsDedicatedSocket": true,
                "clientTypeUUID": "1910A70F-DBC0-4242-AF95-115DB30604E1",
            ]]])
            guard let flujos = flujo.plist?["streams"] as? [[String: Any]],
                  let puertoDatos = (flujos.first?["dataPort"] as? NSNumber)?.uint16Value else {
                throw ErrorControl.sinRespuesta("El Apple TV")
            }
            let datos = try await conectar(puertoDatos)
            await datos.cifrar(con: CanalHAP(
                secreto: r.compartido, sal: "DataStream-Salt\(semilla)",
                infoEnviar: "DataStream-Output-Encryption-Key", infoRecibir: "DataStream-Input-Encryption-Key"
            ))
            self.datos = datos
            tareas.append(Task { await self.leerDatos(datos) })
            for m in MRP.saludo(nombre: "Mando") { try await enviarMRP(m) }
            tareas.append(Task { await self.latir() })
        } catch {
            cerrar()
            throw error
        }
    }

    func cerrar() {
        tareas.forEach { $0.cancel() }
        tareas.removeAll()
        let tubos = [control, avisos, datos].compactMap { $0 }
        control = nil
        avisos = nil
        datos = nil
        Task { for t in tubos { await t.cerrar() } }
    }

    // MARK: - RTSP

    private func rtsp(_ metodo: String, ruta: String? = nil, cuerpo: [String: Any]? = nil) async throws -> MensajeHTTP {
        guard let control else { throw ErrorControl.sinRespuesta("El Apple TV") }
        var encabezados = [
            ("CSeq", String(cseq)), ("DACP-ID", dacp), ("Active-Remote", remoto),
            ("Client-Instance", dacp), ("User-Agent", Self.agente),
        ]
        cseq += 1
        var datos = Data()
        if let cuerpo {
            datos = try PropertyListSerialization.data(fromPropertyList: cuerpo, format: .binary, options: 0)
            encabezados.append(("Content-Type", "application/x-apple-binary-plist"))
        }
        try await control.enviar(MensajeHTTP.peticion("\(metodo) \(ruta ?? uri) RTSP/1.0", encabezados: encabezados, cuerpo: datos))
        let respuesta = try await control.mensaje(limite: .seconds(4))
        guard respuesta.codigo == 200 else {
            // 470: credenciales que la tele no acepta.
            throw respuesta.codigo == 470 ? ErrorControl.porEmparejar : ErrorControl.sinRespuesta("El Apple TV")
        }
        return respuesta
    }

    /// Cada 2 segundos, como iOS: sin esto la tele cierra la sesión.
    private func latir() async {
        var fallas = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            do {
                _ = try await rtsp("POST", ruta: "/feedback")
                fallas = 0
            } catch {
                fallas += 1
                if fallas > 1 { cerrar(); avisar(nil); return }
            }
        }
    }

    /// La tele manda peticiones por aquí; basta contestarle que sí.
    private func contestarAvisos(_ tubo: Tubo) async {
        while !Task.isCancelled {
            guard let m = try? await tubo.mensaje(limite: .seconds(3600)) else { return }
            let respuesta = MensajeHTTP.peticion("RTSP/1.0 200 OK", encabezados: [
                ("Content-Length", "0"), ("Audio-Latency", "0"),
                ("Server", m.encabezados["server"] ?? "AirTunes"), ("CSeq", m.encabezados["cseq"] ?? "0"),
            ])
            try? await tubo.enviar(respuesta)
        }
    }

    // MARK: - Datos

    /// El encabezado de 32 bytes del canal de datos: largo total, tipo
    /// («sync» o «rply»), comando («comm»), número de secuencia y relleno.
    static func trama(tipo: String, comando: String, secuencia: UInt64, cuerpo: Data = Data()) -> Data {
        var d = Data()
        d.append(contentsOf: withUnsafeBytes(of: UInt32(32 + cuerpo.count).bigEndian, Array.init))
        d.append(Data(tipo.utf8).prefix(12) + Data(count: max(0, 12 - tipo.utf8.count)))
        d.append(Data(comando.utf8).prefix(4) + Data(count: max(0, 4 - comando.utf8.count)))
        d.append(contentsOf: withUnsafeBytes(of: secuencia.bigEndian, Array.init))
        d.append(contentsOf: [0, 0, 0, 0])
        d.append(cuerpo)
        return d
    }

    /// pyatv usa el mismo número de secuencia en todo lo que manda.
    private let secuencia = UInt64.random(in: 0x1_0000_0000...0x1_FFFF_FFFF)

    private func enviarMRP(_ mensaje: Data) async throws {
        guard let datos else { return }
        let cuerpo = try PropertyListSerialization.data(
            fromPropertyList: ["params": ["data": Marco.envolver(mensaje)]], format: .binary, options: 0
        )
        try await datos.enviar(Self.trama(tipo: "sync", comando: "comm", secuencia: secuencia, cuerpo: cuerpo))
    }

    private func leerDatos(_ tubo: Tubo) async {
        while !Task.isCancelled {
            guard let cabeza = try? await tubo.tomar(32, limite: .seconds(3600)) else { break }
            let largo = Int(cabeza.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard largo >= 32, let cuerpo = try? await tubo.tomar(largo - 32, limite: .seconds(10)) else { break }
            let tipo = String(decoding: cabeza[4..<8], as: UTF8.self)
            if tipo == "sync" {
                // Todo «sync» se contesta con un «rply» del mismo número.
                let secuencia = cabeza[20..<28].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                try? await tubo.enviar(Self.trama(tipo: "rply", comando: "", secuencia: secuencia))
            }
            guard !cuerpo.isEmpty,
                  let plist = (try? PropertyListSerialization.propertyList(from: cuerpo, format: nil)) as? [String: Any],
                  let datos = (plist["params"] as? [String: Any])?["data"] as? Data else { continue }
            for mensaje in MRP.separar(datos) {
                if let pedido = estado.recibir(mensaje) { try? await enviarMRP(pedido) }
            }
            avisar(estado.reproduciendo)
        }
        cerrar()
        avisar(nil)
    }

    private func avisar(_ r: Reproduciendo?) {
        // Sólo si cambió algo más que la posición: la barra avanza sola.
        if let ultimo = ultimoAviso, ultimo == r { return }
        ultimoAviso = .some(r)
        alCambiar(r, estado.app)
    }

    // MARK: - Red

    private func conectar(_ p: UInt16) async throws -> Tubo {
        do {
            return Tubo(try await TCP.conectar(a: host, puerto: p, limite: .seconds(3)))
        } catch {
            throw ErrorControl.sinRespuesta("El Apple TV")
        }
    }

    private func pedirHTTP(_ tubo: Tubo, _ ruta: String, cuerpo: Data) async throws -> Data {
        try await tubo.enviar(MensajeHTTP.peticion("POST \(ruta) HTTP/1.1", encabezados: [
            ("User-Agent", "AirPlay/320.20"), ("Connection", "keep-alive"),
            ("X-Apple-HKP", "3"), ("Content-Type", "application/octet-stream"),
        ], cuerpo: cuerpo))
        let r = try await tubo.mensaje()
        guard r.codigo == 200 else {
            throw r.codigo == 470 ? ErrorControl.porEmparejar : ErrorControl.sinRespuesta("El Apple TV")
        }
        return r.cuerpo
    }

    private static func ipLocal(_ c: NWConnection) -> String? {
        guard case .hostPort(let h, _) = c.currentPath?.localEndpoint else { return nil }
        switch h {
        case .ipv4(let ip): return "\(ip)"
        case .ipv6(let ip): return "\(ip)".components(separatedBy: "%").first
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }
}
