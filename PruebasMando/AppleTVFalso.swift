import CryptoKit
import Foundation
import Network
@testable import Mando

/// Un Apple TV de mentira que habla Companion: el lado servidor del alta con
/// SRP (con su propia cuenta, la de RFC 5054), la verificación con firmas, el
/// canal cifrado y las respuestas a las peticiones de la app.
nonisolated final class AppleTVFalso: @unchecked Sendable {
    let pin = "1234"
    private let candado = NSLock()
    private let cola = DispatchQueue(label: "apple-tv-falso")
    private var oyente: NWListener?
    private var conexiones: [NWConnection] = []

    /// La identidad del Apple TV. El AirPlay falso puede usar la misma, como
    /// la tele real, para probar que las llaves de Companion sirven en AirPlay.
    let id = Data("AppleTVFalso".utf8)
    let llave = Curve25519.Signing.PrivateKey()
    /// Los teléfonos emparejados: identificador → llave pública.
    private var conocidos: [Data: Data] = [:]
    var emparejados: [Data: Data] { candado.withLock { conocidos } }

    private(set) var peticiones: [String] = []
    private(set) var teclas: [Int64] = []
    private(set) var apps: [String] = []
    /// Lo que llega al campo de texto: "" cuando se borra, y el texto.
    private(set) var textos: [String] = []
    /// Los nombres de clase con que llegaron los archivos de texto.
    private(set) var clasesDeTexto: Set<String> = []
    /// Si hay un campo de texto activo en la tele (la búsqueda abierta).
    var campoAbierto = false
    let sesionDeTexto = UUID()

    func arrancar() async throws -> UInt16 {
        let o = try NWListener(using: .tcp, on: .any)
        o.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.candado.withLock { self.conexiones.append(c) }
            c.start(queue: self.cola)
            self.leer(c, sesion: Sesion())
        }
        oyente = o
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

    func apagar() {
        oyente?.cancel()
        candado.withLock { conexiones.forEach { $0.cancel() } }
    }

    /// Como «Quitar este aparato» en Ajustes del Apple TV.
    func olvidarEmparejamientos() {
        candado.withLock { conocidos.removeAll() }
    }

    // MARK: - Por conexión

    private final class Sesion: @unchecked Sendable {
        var bufer = Data()
        var srp: (sal: Data, b: EnteroGrande, v: EnteroGrande, publicaB: EnteroGrande)?
        var llaveSRP: Data?
        var efimera: Curve25519.KeyAgreement.PrivateKey?
        var compartido: Data?
        var clientePublica: Data?
        var canal: Canal?
    }

    private func leer(_ c: NWConnection, sesion: Sesion) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] datos, _, completo, error in
            guard let self, error == nil else { return }
            if let datos { sesion.bufer.append(datos) }
            while let t = Trama.extraer(de: &sesion.bufer) {
                self.atender(t, sesion, c)
            }
            if !completo { self.leer(c, sesion: sesion) }
        }
    }

    private func atender(_ t: Trama, _ s: Sesion, _ c: NWConnection) {
        if t.tipo == Trama.Tipo.cifrada {
            guard var canal = s.canal, let claro = try? canal.descifrar(t),
                  let m = try? OPACK.desempacar(claro) else { return }
            s.canal = canal
            responder(m, s, c)
            return
        }
        guard let pd = (try? OPACK.desempacar(t.datos))?["_pd"]?.datos else { return }
        let tlv = TLV8.leer(pd)
        let estado = tlv[TLV8.estado]?.first ?? 0
        switch (t.tipo, estado) {
        case (Trama.Tipo.altaInicio, 1): altaM2(s, c)
        case (Trama.Tipo.altaSiguiente, 3): altaM4(tlv, s, c)
        case (Trama.Tipo.altaSiguiente, 5): altaM6(tlv, s, c)
        case (Trama.Tipo.verificarInicio, 1): verificarM2(tlv, s, c)
        case (Trama.Tipo.verificarSiguiente, 3): verificarM4(tlv, s, c)
        default: break
        }
    }

    private func mandar(_ tipo: UInt8, _ tlv: [(UInt8, Data)], _ c: NWConnection) {
        let pd = OPACK.dic(["_pd": .datos(TLV8.armar(tlv))]).empacado
        c.send(content: Trama.armar(tipo, pd), completion: .idempotent)
    }

    // MARK: - Alta, lado servidor de SRP

    private func altaM2(_ s: Sesion, _ c: NWConnection) {
        let grupo = SRPCliente.grupo
        let g = SRPCliente.g
        let sal = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let b = EnteroGrande(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let x = EnteroGrande(H(sal, H(Data("Pair-Setup:\(pin)".utf8))))
        let v = grupo.potencia(g, x)
        let k = EnteroGrande(H(grupo.n.bytes(), g.bytes(longitud: SRPCliente.largo)))
        let publicaB = grupo.sumar(grupo.multiplicar(k, v), grupo.potencia(g, b))
        s.srp = (sal, b, v, publicaB)
        mandar(Trama.Tipo.altaSiguiente, [(TLV8.estado, Data([2])), (TLV8.sal, sal), (TLV8.llavePublica, publicaB.bytes())], c)
    }

    private func altaM4(_ tlv: [UInt8: Data], _ s: Sesion, _ c: NWConnection) {
        guard let srp = s.srp, let aDatos = tlv[TLV8.llavePublica], let m1 = tlv[TLV8.prueba] else { return }
        let grupo = SRPCliente.grupo
        let largo = SRPCliente.largo
        let a = EnteroGrande(aDatos)
        let u = EnteroGrande(H(a.bytes(longitud: largo), srp.publicaB.bytes(longitud: largo)))
        let S = grupo.potencia(grupo.multiplicar(a, grupo.potencia(srp.v, u)), srp.b)
        let K = H(S.bytes())
        let xor = Data(zip(H(grupo.n.bytes()), H(SRPCliente.g.bytes())).map { $0 ^ $1 })
        let esperada = H(xor, H(Data("Pair-Setup".utf8)), srp.sal, a.bytes(), srp.publicaB.bytes(), K)
        guard esperada == m1 else {
            // kTLVError_Authentication: el PIN no coincide.
            mandar(Trama.Tipo.altaSiguiente, [(TLV8.estado, Data([4])), (TLV8.error, Data([2]))], c)
            return
        }
        s.llaveSRP = K
        mandar(Trama.Tipo.altaSiguiente, [(TLV8.estado, Data([4])), (TLV8.prueba, H(a.bytes(), m1, K))], c)
    }

    private func altaM6(_ tlv: [UInt8: Data], _ s: Sesion, _ c: NWConnection) {
        guard let K = s.llaveSRP, let cifrado = tlv[TLV8.cifrado],
              let claro = try? HAP.descifrar(cifrado, HAP.derivar(K, sal: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info"), nonce: "PS-Msg05")
        else { return }
        let interno = TLV8.leer(claro)
        guard let suId = interno[TLV8.identificador], let suLlave = interno[TLV8.llavePublica],
              let firma = interno[TLV8.firma],
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: suLlave) else { return }
        let x = HAP.derivar(K, sal: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        guard pub.isValidSignature(firma, for: x.withUnsafeBytes { Data($0) } + suId + suLlave) else {
            mandar(Trama.Tipo.altaSiguiente, [(TLV8.estado, Data([6])), (TLV8.error, Data([2]))], c)
            return
        }
        candado.withLock { conocidos[suId] = suLlave }

        let nuestra = llave.publicKey.rawRepresentation
        let y = HAP.derivar(K, sal: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let nuestraFirma = try! llave.signature(for: y.withUnsafeBytes { Data($0) } + id + nuestra)
        let respuesta = try! HAP.cifrar(
            TLV8.armar([(TLV8.identificador, id), (TLV8.llavePublica, nuestra), (TLV8.firma, nuestraFirma)]),
            HAP.derivar(K, sal: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info"),
            nonce: "PS-Msg06"
        )
        mandar(Trama.Tipo.altaSiguiente, [(TLV8.estado, Data([6])), (TLV8.cifrado, respuesta)], c)
    }

    // MARK: - Verificación

    private func verificarM2(_ tlv: [UInt8: Data], _ s: Sesion, _ c: NWConnection) {
        guard let suya = tlv[TLV8.llavePublica],
              let suyaLlave = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: suya) else { return }
        let efimera = Curve25519.KeyAgreement.PrivateKey()
        let compartido = try! efimera.sharedSecretFromKeyAgreement(with: suyaLlave).withUnsafeBytes { Data($0) }
        s.efimera = efimera
        s.compartido = compartido
        s.clientePublica = suya
        let nuestra = efimera.publicKey.rawRepresentation
        let firma = try! llave.signature(for: nuestra + id + suya)
        let cifrado = try! HAP.cifrar(
            TLV8.armar([(TLV8.identificador, id), (TLV8.firma, firma)]),
            HAP.derivar(compartido, sal: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info"),
            nonce: "PV-Msg02"
        )
        mandar(Trama.Tipo.verificarSiguiente, [(TLV8.estado, Data([2])), (TLV8.llavePublica, nuestra), (TLV8.cifrado, cifrado)], c)
    }

    private func verificarM4(_ tlv: [UInt8: Data], _ s: Sesion, _ c: NWConnection) {
        guard let compartido = s.compartido, let efimera = s.efimera, let suya = s.clientePublica,
              let cifrado = tlv[TLV8.cifrado],
              let claro = try? HAP.descifrar(cifrado, HAP.derivar(compartido, sal: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info"), nonce: "PV-Msg03")
        else { return }
        let interno = TLV8.leer(claro)
        let conocida = interno[TLV8.identificador].flatMap { i in candado.withLock { conocidos[i] } }
        guard let conocida, let firma = interno[TLV8.firma],
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: conocida),
              pub.isValidSignature(firma, for: suya + interno[TLV8.identificador]! + efimera.publicKey.rawRepresentation)
        else {
            mandar(Trama.Tipo.verificarSiguiente, [(TLV8.estado, Data([4])), (TLV8.error, Data([2]))], c)
            return
        }
        mandar(Trama.Tipo.verificarSiguiente, [(TLV8.estado, Data([4]))], c)
        // Del lado de la tele las llaves van al revés que en el teléfono.
        s.canal = Canal(
            enviar: HAP.derivar(compartido, sal: "", info: "ServerEncrypt-main"),
            recibir: HAP.derivar(compartido, sal: "", info: "ClientEncrypt-main")
        )
    }

    private func leerTexto(_ archivo: Data) {
        if let plist = try? PropertyListSerialization.propertyList(from: archivo, format: nil) as? [String: Any],
           let objetos = plist["$objects"] as? [Any] {
            for case let d as [String: Any] in objetos {
                if let nombre = d["$classname"] as? String { clasesDeTexto.insert(nombre) }
            }
        }
        let lector = try? NSKeyedUnarchiver(forReadingFrom: archivo)
        lector?.requiresSecureCoding = false
        lector?.setClass(TextoCompanion.Operaciones.self, forClassName: "RTITextOperations")
        lector?.setClass(TextoCompanion.Salida.self, forClassName: "TIKeyboardOutput")
        guard let op = lector?.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? TextoCompanion.Operaciones,
              op.sesion == sesionDeTexto else { return }
        textos.append(op.afirmar ?? op.salida.texto ?? "")
    }

    // MARK: - Canal cifrado

    private func responder(_ m: OPACK, _ s: Sesion, _ c: NWConnection) {
        guard let nombre = m["_i"]?.texto, let x = m["_x"] else { return }
        let contenido = m["_c"]
        var respuesta = OPACK.dic([:])
        candado.withLock {
            peticiones.append(nombre)
            switch nombre {
            case "FetchAttentionState": respuesta = .dic(["state": .entero(3)])
            case "FetchLaunchableApplicationsEvent":
                respuesta = .dic(["com.firecore.infuse": .texto("Infuse"), "com.plex.client": .texto("Plex")])
            case "_hidC":
                // Sólo al apretar: soltar es la misma tecla.
                if contenido?["_hBtS"]?.entero == 1, let t = contenido?["_hidC"]?.entero { teclas.append(t) }
            case "_launchApp":
                if let app = contenido?["_bundleID"]?.texto { apps.append(app) }
            case "_tiStart" where campoAbierto:
                // Como el real: la sesión viene dentro de un archivo con más cosas.
                let archivo = try! NSKeyedArchiver.archivedData(
                    withRootObject: ["sessionUUID": sesionDeTexto as NSUUID, "documentState": "algo"] as NSDictionary,
                    requiringSecureCoding: false
                )
                respuesta = .dic(["_tiD": .datos(archivo)])
            case "_tiC":
                if let archivo = contenido?["_tiD"]?.datos { leerTexto(archivo) }
            default: break
            }
        }
        guard var canal = s.canal else { return }
        let mensaje = OPACK.dic(["_x": x, "_t": .entero(3), "_c": respuesta])
        if let datos = try? canal.cifrar(Trama.Tipo.cifrada, mensaje.empacado) {
            s.canal = canal
            c.send(content: datos, completion: .idempotent)
        }
    }
}
