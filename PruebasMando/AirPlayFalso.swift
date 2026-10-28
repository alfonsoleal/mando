import CryptoKit
import Foundation
import Network
@testable import Mando

/// El lado AirPlay 2 de un Apple TV, de mentira: emparejamiento por HTTP con
/// PIN, verificación, la conexión de control cifrada con RTSP, el canal de
/// avisos (pregunta una vez y espera el 200) y el canal de datos con MRP,
/// donde manda lo que suena y la portada cuando se la piden.
nonisolated final class AirPlayFalso: @unchecked Sendable {
    let pin = "4321"
    private let candado = NSLock()
    private var oyentes: [NWListener] = []
    private var tubos: [Tubo] = []

    private let id: Data
    private let llave: Curve25519.Signing.PrivateKey
    private var conocidos: [Data: Data]

    private(set) var tiposMRP: [Int] = []
    private(set) var respuestasRply = 0
    private(set) var latidos = 0
    private(set) var avisosContestados = 0
    private(set) var pedidosDePortada = 0
    let portada = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])

    /// Con `identidadDe` usa la misma identidad y los mismos emparejados que
    /// el Apple TV de Companion: así se prueba que esas llaves sirven aquí.
    init(identidadDe companion: AppleTVFalso? = nil) {
        id = companion?.id ?? Data("AirPlayFalso".utf8)
        llave = companion?.llave ?? Curve25519.Signing.PrivateKey()
        conocidos = companion?.emparejados ?? [:]
    }

    func arrancar() async throws -> UInt16 {
        try await escuchar { [weak self] t in await self?.atenderControl(t) }
    }

    func apagar() {
        candado.withLock { oyentes.forEach { $0.cancel() } }
        let todos = candado.withLock { tubos }
        Task { for t in todos { await t.cerrar() } }
    }

    // MARK: - Red

    private func escuchar(_ atender: @escaping @Sendable (Tubo) async -> Void) async throws -> UInt16 {
        let o = try NWListener(using: .tcp, on: .any)
        let cola = DispatchQueue(label: "airplay-falso")
        o.newConnectionHandler = { [weak self] c in
            let t = Tubo(c)
            self?.candado.withLock { self?.tubos.append(t) }
            c.start(queue: cola)
            Task { await atender(t) }
        }
        candado.withLock { oyentes.append(o) }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let una = Unico()
            o.stateUpdateHandler = { e in
                switch e {
                case .ready: if una.primero() { k.resume() }
                case .failed(let err): if una.primero() { k.resume(throwing: err) }
                default: break
                }
            }
            o.start(queue: cola)
        }
        return o.port!.rawValue
    }

    private func responder(_ t: Tubo, protocolo: String = "HTTP/1.1", codigo: Int = 200, cseq: String? = nil, cuerpo: Data = Data(), plist: [String: Any]? = nil) async {
        var encabezados: [(String, String)] = []
        if let cseq { encabezados.append(("CSeq", cseq)) }
        var datos = cuerpo
        if let plist {
            datos = try! PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            encabezados.append(("Content-Type", "application/x-apple-binary-plist"))
        }
        try? await t.enviar(MensajeHTTP.peticion("\(protocolo) \(codigo) \(codigo == 200 ? "OK" : "Error")", encabezados: encabezados, cuerpo: datos))
    }

    // MARK: - Control: emparejar, verificar y RTSP

    private func atenderControl(_ t: Tubo) async {
        var srp: (sal: Data, b: EnteroGrande, v: EnteroGrande, publicaB: EnteroGrande)?
        var llaveSRP: Data?
        var efimera: Curve25519.KeyAgreement.PrivateKey?
        var compartido: Data?
        var suPublica: Data?

        while let m = try? await t.mensaje(limite: .seconds(30)) {
            let ruta = m.primeraLinea.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let metodo = m.primeraLinea.split(separator: " ").first.map(String.init) ?? ""
            let cseq = m.encabezados["cseq"]
            let tlv = TLV8.leer(m.cuerpo)
            let estado = tlv[TLV8.estado]?.first ?? 0

            switch (metodo, ruta, estado) {
            case ("POST", "/pair-pin-start", _):
                await responder(t)

            case ("POST", "/pair-setup", 1):
                let g = SRPCliente.g, grupo = SRPCliente.grupo
                let sal = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
                let b = EnteroGrande(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
                let v = grupo.potencia(g, EnteroGrande(H(sal, H(Data("Pair-Setup:\(pin)".utf8)))))
                let k = EnteroGrande(H(grupo.n.bytes(), g.bytes(longitud: SRPCliente.largo)))
                let B = grupo.sumar(grupo.multiplicar(k, v), grupo.potencia(g, b))
                srp = (sal, b, v, B)
                await responder(t, cuerpo: TLV8.armar([(TLV8.estado, Data([2])), (TLV8.sal, sal), (TLV8.llavePublica, B.bytes())]))

            case ("POST", "/pair-setup", 3):
                guard let s = srp, let aDatos = tlv[TLV8.llavePublica], let m1 = tlv[TLV8.prueba] else { return }
                let grupo = SRPCliente.grupo, largo = SRPCliente.largo
                let a = EnteroGrande(aDatos)
                let u = EnteroGrande(H(a.bytes(longitud: largo), s.publicaB.bytes(longitud: largo)))
                let K = H(grupo.potencia(grupo.multiplicar(a, grupo.potencia(s.v, u)), s.b).bytes())
                let xor = Data(zip(H(grupo.n.bytes()), H(SRPCliente.g.bytes())).map { $0 ^ $1 })
                guard H(xor, H(Data("Pair-Setup".utf8)), s.sal, a.bytes(), s.publicaB.bytes(), K) == m1 else {
                    await responder(t, cuerpo: TLV8.armar([(TLV8.estado, Data([4])), (TLV8.error, Data([2]))]))
                    continue
                }
                llaveSRP = K
                await responder(t, cuerpo: TLV8.armar([(TLV8.estado, Data([4])), (TLV8.prueba, H(a.bytes(), m1, K))]))

            case ("POST", "/pair-setup", 5):
                guard let K = llaveSRP, let cifrado = tlv[TLV8.cifrado],
                      let claro = try? HAP.descifrar(cifrado, HAP.derivar(K, sal: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info"), nonce: "PS-Msg05")
                else { return }
                let interno = TLV8.leer(claro)
                if let i = interno[TLV8.identificador], let p = interno[TLV8.llavePublica] {
                    candado.withLock { conocidos[i] = p }
                }
                let nuestra = llave.publicKey.rawRepresentation
                let y = HAP.derivar(K, sal: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
                let firma = try! llave.signature(for: y.withUnsafeBytes { Data($0) } + id + nuestra)
                let respuesta = try! HAP.cifrar(
                    TLV8.armar([(TLV8.identificador, id), (TLV8.llavePublica, nuestra), (TLV8.firma, firma)]),
                    HAP.derivar(K, sal: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info"), nonce: "PS-Msg06"
                )
                await responder(t, cuerpo: TLV8.armar([(TLV8.estado, Data([6])), (TLV8.cifrado, respuesta)]))

            case ("POST", "/pair-verify", 1):
                guard let suya = tlv[TLV8.llavePublica],
                      let suyaLlave = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: suya) else { return }
                let e = Curve25519.KeyAgreement.PrivateKey()
                let c = try! e.sharedSecretFromKeyAgreement(with: suyaLlave).withUnsafeBytes { Data($0) }
                efimera = e; compartido = c; suPublica = suya
                let nuestra = e.publicKey.rawRepresentation
                let firma = try! llave.signature(for: nuestra + id + suya)
                let cifrado = try! HAP.cifrar(
                    TLV8.armar([(TLV8.identificador, id), (TLV8.firma, firma)]),
                    HAP.derivar(c, sal: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info"), nonce: "PV-Msg02"
                )
                await responder(t, cuerpo: TLV8.armar([(TLV8.estado, Data([2])), (TLV8.llavePublica, nuestra), (TLV8.cifrado, cifrado)]))

            case ("POST", "/pair-verify", 3):
                guard let c = compartido, let e = efimera, let suya = suPublica, let cifrado = tlv[TLV8.cifrado],
                      let claro = try? HAP.descifrar(cifrado, HAP.derivar(c, sal: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info"), nonce: "PV-Msg03")
                else { return }
                let interno = TLV8.leer(claro)
                let conocida = interno[TLV8.identificador].flatMap { i in candado.withLock { conocidos[i] } }
                guard let conocida, let firma = interno[TLV8.firma],
                      let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: conocida),
                      pub.isValidSignature(firma, for: suya + interno[TLV8.identificador]! + e.publicKey.rawRepresentation)
                else {
                    await responder(t, cuerpo: TLV8.armar([(TLV8.estado, Data([4])), (TLV8.error, Data([2]))]))
                    continue
                }
                await responder(t, cuerpo: TLV8.armar([(TLV8.estado, Data([4]))]))
                // Desde aquí la conexión va cifrada; del lado de la tele las
                // llaves de leer y escribir van al revés.
                await t.cifrar(con: CanalHAP(secreto: c, sal: "Control-Salt",
                    infoEnviar: "Control-Read-Encryption-Key", infoRecibir: "Control-Write-Encryption-Key"))

            case ("SETUP", _, _):
                guard let c = compartido, let cuerpo = m.plist else { return }
                if cuerpo["isRemoteControlOnly"] as? Bool == true {
                    let p = try? await escuchar { [weak self] e in await self?.atenderAvisos(e, compartido: c) }
                    await responder(t, protocolo: "RTSP/1.0", cseq: cseq, plist: ["eventPort": p ?? 0])
                } else if let flujos = cuerpo["streams"] as? [[String: Any]],
                          let semilla = (flujos.first?["seed"] as? NSNumber)?.uint64Value {
                    let p = try? await escuchar { [weak self] d in await self?.atenderDatos(d, compartido: c, semilla: semilla) }
                    await responder(t, protocolo: "RTSP/1.0", cseq: cseq, plist: ["streams": [["dataPort": p ?? 0, "type": 130]]])
                }

            case ("RECORD", _, _):
                await responder(t, protocolo: "RTSP/1.0", cseq: cseq)

            case ("POST", "/feedback", _):
                candado.withLock { latidos += 1 }
                await responder(t, protocolo: "RTSP/1.0", cseq: cseq)

            default:
                await responder(t, codigo: 404)
            }
        }
    }

    // MARK: - Avisos

    private func atenderAvisos(_ t: Tubo, compartido: Data) async {
        await t.cifrar(con: CanalHAP(secreto: compartido, sal: "Events-Salt",
            infoEnviar: "Events-Write-Encryption-Key", infoRecibir: "Events-Read-Encryption-Key"))
        // Como la tele: pregunta algo y espera el 200.
        try? await t.enviar(MensajeHTTP.peticion("POST /command RTSP/1.0", encabezados: [("CSeq", "7"), ("Server", "AirTunes/1")]))
        if let r = try? await t.mensaje(limite: .seconds(5)), r.codigo == 200, r.encabezados["cseq"] == "7" {
            candado.withLock { avisosContestados += 1 }
        }
    }

    // MARK: - Datos (MRP)

    private func atenderDatos(_ t: Tubo, compartido: Data, semilla: UInt64) async {
        await t.cifrar(con: CanalHAP(secreto: compartido, sal: "DataStream-Salt\(semilla)",
            infoEnviar: "DataStream-Input-Encryption-Key", infoRecibir: "DataStream-Output-Encryption-Key"))
        var saludado = false
        while let cabeza = try? await t.tomar(32, limite: .seconds(30)) {
            let largo = Int(cabeza.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            guard let cuerpo = try? await t.tomar(largo - 32) else { return }
            if cabeza[4..<8] == Data("rply".utf8) {
                candado.withLock { respuestasRply += 1 }
                continue
            }
            guard let plist = (try? PropertyListSerialization.propertyList(from: cuerpo, format: nil)) as? [String: Any],
                  let datos = (plist["params"] as? [String: Any])?["data"] as? Data else { continue }
            for m in MRP.separar(datos) {
                let tipo = Int(Protobuf.campos(m)[1]?.entero ?? 0)
                candado.withLock { tiposMRP.append(tipo) }
                if tipo == MRP.playbackQueueRequest.tipo {
                    candado.withLock { pedidosDePortada += 1 }
                    let ident = Protobuf.campos(m)[2]?.texto
                    await mandarMRP(t, estado(conPortada: true, identificador: ident))
                }
            }
            // Ya saludó el teléfono: la tele cuenta qué suena.
            if !saludado, candado.withLock({ tiposMRP.contains(MRP.clientUpdatesConfig.tipo) }) {
                saludado = true
                await mandarMRP(t, MRP.mensaje(MRP.setNowPlayingClient) { s in
                    s.mensaje(1) { c in c.texto(2, "com.firecore.infuse") }
                })
                await mandarMRP(t, estado(conPortada: false, identificador: nil))
            }
        }
    }

    /// SET_STATE de Infuse: un episodio de Severance a los 18:40 de 52 minutos.
    private func estado(conPortada: Bool, identificador: String?) -> Data {
        MRP.mensaje(MRP.setState, identificador: identificador) { s in
            s.mensaje(3) { cola in
                cola.entero(1, 0)
                cola.mensaje(2) { item in
                    item.texto(1, "episodio-1")
                    item.mensaje(2) { md in
                        md.texto(1, "La isla de los perros")
                        md.entero(10, 2)
                        md.entero(11, 5)
                        md.doble(14, 52 * 60)
                        md.booleano(19, true)
                        md.doble(35, 18 * 60 + 40)
                        md.texto(63, "Severance")
                        md.doble(74, Date.now.timeIntervalSinceReferenceDate)
                    }
                    if conPortada { item.bytes(3, portada) }
                }
            }
            s.entero(6, 1)
            s.mensaje(9) { ruta in
                ruta.mensaje(2) { c in c.texto(2, "com.firecore.infuse") }
                ruta.mensaje(3) { p in p.texto(1, "MediaRemote-DefaultPlayer") }
            }
        }
    }

    private func mandarMRP(_ t: Tubo, _ mensaje: Data) async {
        let cuerpo = try! PropertyListSerialization.data(
            fromPropertyList: ["params": ["data": Marco.envolver(mensaje)]], format: .binary, options: 0)
        try? await t.enviar(SesionAirPlay.trama(tipo: "sync", comando: "comm", secuencia: 99, cuerpo: cuerpo))
    }
}
