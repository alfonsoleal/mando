import CryptoKit
import Foundation

/// El emparejamiento de Apple (el de HomeKit, que Companion reutiliza): SRP
/// para probar el PIN, Ed25519 para que cada lado firme con su llave de
/// largo plazo, X25519 para la llave de cada sesión y ChaCha20-Poly1305 para
/// cifrar. Aquí sólo hay cuentas y formatos; la red vive en el controlador.
nonisolated enum HAP {
    /// HKDF-SHA512 con sal e información de texto, como las define Apple.
    static func derivar(_ secreto: Data, sal: String, info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secreto),
            salt: Data(sal.utf8),
            info: Data(info.utf8),
            outputByteCount: 32
        )
    }

    /// Los mensajes del emparejamiento usan un nonce de texto («PS-Msg05»)
    /// precedido de cuatro ceros.
    static func cifrar(_ datos: Data, _ llave: SymmetricKey, nonce: String) throws -> Data {
        let n = try ChaChaPoly.Nonce(data: Data(count: 4) + Data(nonce.utf8))
        let caja = try ChaChaPoly.seal(datos, using: llave, nonce: n)
        return caja.ciphertext + caja.tag
    }

    static func descifrar(_ datos: Data, _ llave: SymmetricKey, nonce: String) throws -> Data {
        guard datos.count >= 16 else { throw ErrorControl.emparejamientoRechazado }
        let n = try ChaChaPoly.Nonce(data: Data(count: 4) + Data(nonce.utf8))
        let caja = try ChaChaPoly.SealedBox(nonce: n, ciphertext: datos.dropLast(16), tag: datos.suffix(16))
        return try ChaChaPoly.open(caja, using: llave)
    }

    // MARK: - Alta (pair-setup)

    static func altaM1() -> Data {
        TLV8.armar([(TLV8.metodo, Data([0])), (TLV8.estado, Data([1]))])
    }

    static func altaM3(_ srp: SRPCliente.Resultado) -> Data {
        TLV8.armar([(TLV8.estado, Data([3])), (TLV8.llavePublica, srp.publica), (TLV8.prueba, srp.prueba)])
    }

    /// M5: el teléfono se presenta con su identificador y su llave de largo
    /// plazo, firmados con una llave derivada de la sesión SRP.
    static func altaM5(llaveSRP: Data, credenciales c: Credenciales, extra: Data) throws -> Data {
        let x = derivar(llaveSRP, sal: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info")
        let propia = try Curve25519.Signing.PrivateKey(rawRepresentation: c.llavePrivada)
        let publica = propia.publicKey.rawRepresentation
        let id = Data(c.clienteId.utf8)
        let firma = try propia.signature(for: x.withUnsafeBytes { Data($0) } + id + publica)
        var interno: [(UInt8, Data)] = [(TLV8.identificador, id), (TLV8.llavePublica, publica), (TLV8.firma, firma)]
        if !extra.isEmpty { interno.append((TLV8.nombre, extra)) }
        let llave = derivar(llaveSRP, sal: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let cifrado = try cifrar(TLV8.armar(interno), llave, nonce: "PS-Msg05")
        return TLV8.armar([(TLV8.estado, Data([5])), (TLV8.cifrado, cifrado)])
    }

    /// M6: el Apple TV se presenta igual. Regresa su identificador y su llave
    /// pública de largo plazo, ya con la firma revisada.
    static func altaM6(_ tlv: [UInt8: Data], llaveSRP: Data) throws -> (id: Data, llave: Data) {
        guard let cifrado = tlv[TLV8.cifrado] else { throw ErrorControl.emparejamientoRechazado }
        let llave = derivar(llaveSRP, sal: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info")
        let interno = TLV8.leer(try descifrar(cifrado, llave, nonce: "PS-Msg06"))
        guard let id = interno[TLV8.identificador],
              let publica = interno[TLV8.llavePublica],
              let firma = interno[TLV8.firma] else { throw ErrorControl.emparejamientoRechazado }
        let x = derivar(llaveSRP, sal: "Pair-Setup-Accessory-Sign-Salt", info: "Pair-Setup-Accessory-Sign-Info")
        let suya = try Curve25519.Signing.PublicKey(rawRepresentation: publica)
        guard suya.isValidSignature(firma, for: x.withUnsafeBytes { Data($0) } + id + publica) else {
            throw ErrorControl.emparejamientoRechazado
        }
        return (id, publica)
    }

    // MARK: - Verificación (pair-verify), en cada conexión

    struct Verificacion {
        let efimera = Curve25519.KeyAgreement.PrivateKey()

        var m1: Data {
            TLV8.armar([(TLV8.estado, Data([1])), (TLV8.llavePublica, efimera.publicKey.rawRepresentation)])
        }

        /// Revisa que M2 la firmó el Apple TV que emparejamos y arma M3.
        /// Regresa también las llaves de la sesión cifrada.
        func responder(_ m2: [UInt8: Data], credenciales c: Credenciales) throws -> (m3: Data, enviar: SymmetricKey, recibir: SymmetricKey, compartido: Data) {
            guard let suyaDatos = m2[TLV8.llavePublica], let cifrado = m2[TLV8.cifrado] else {
                throw ErrorControl.emparejamientoVencido
            }
            let suya = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: suyaDatos)
            let compartido = try efimera.sharedSecretFromKeyAgreement(with: suya).withUnsafeBytes { Data($0) }
            let llave = HAP.derivar(compartido, sal: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info")
            let interno = TLV8.leer(try HAP.descifrar(cifrado, llave, nonce: "PV-Msg02"))
            guard let id = interno[TLV8.identificador], let firma = interno[TLV8.firma],
                  id == c.teleId else { throw ErrorControl.emparejamientoVencido }
            let propiaPublica = efimera.publicKey.rawRepresentation
            let ltpk = try Curve25519.Signing.PublicKey(rawRepresentation: c.llaveTele)
            guard ltpk.isValidSignature(firma, for: suyaDatos + id + propiaPublica) else {
                throw ErrorControl.emparejamientoVencido
            }

            let propia = try Curve25519.Signing.PrivateKey(rawRepresentation: c.llavePrivada)
            let clienteId = Data(c.clienteId.utf8)
            let nuestraFirma = try propia.signature(for: propiaPublica + clienteId + suyaDatos)
            let cifradoM3 = try HAP.cifrar(
                TLV8.armar([(TLV8.identificador, clienteId), (TLV8.firma, nuestraFirma)]),
                llave, nonce: "PV-Msg03"
            )
            let m3 = TLV8.armar([(TLV8.estado, Data([3])), (TLV8.cifrado, cifradoM3)])
            // Las llaves de Companion; AirPlay deriva las suyas del mismo
            // secreto con otras sales, por eso también se entrega.
            return (
                m3,
                HAP.derivar(compartido, sal: "", info: "ClientEncrypt-main"),
                HAP.derivar(compartido, sal: "", info: "ServerEncrypt-main"),
                compartido
            )
        }
    }
}

/// Lo que se guarda después de emparejar: quiénes somos nosotros y quién es
/// el Apple TV. Vive en el Llavero; sin esto hay que volver a emparejar.
nonisolated struct Credenciales: Codable, Equatable, Sendable {
    let clienteId: String
    let llavePrivada: Data
    var teleId: Data
    var llaveTele: Data

    static func nuevas() -> Credenciales {
        Credenciales(
            clienteId: UUID().uuidString,
            llavePrivada: Curve25519.Signing.PrivateKey().rawRepresentation,
            teleId: Data(),
            llaveTele: Data()
        )
    }

    var emparejado: Bool { !llaveTele.isEmpty }

    private static let servicio = "mx.alfonsoleal.mando.companion"

    static func leer(_ cuenta: String) -> Credenciales? {
        Llavero.leer(servicio, cuenta).flatMap { try? JSONDecoder().decode(Credenciales.self, from: $0) }
    }

    func guardar(_ cuenta: String) {
        guard let datos = try? JSONEncoder().encode(self) else { return }
        Llavero.guardar(datos, Credenciales.servicio, cuenta)
    }

    static func borrar(_ cuenta: String) {
        Llavero.borrar(servicio, cuenta)
    }
}
