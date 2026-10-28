import CryptoKit
import Foundation

/// El cifrado por bloques de HomeKit que usa AirPlay después de verificar:
/// cada bloque es su largo (2 bytes, little endian), hasta 1024 bytes
/// cifrados con ChaCha20-Poly1305 y la etiqueta de 16. El largo va como dato
/// autenticado y el nonce es un contador por sentido.
///
/// Es distinto del de Companion (`Canal`): allá cada trama ya trae su
/// encabezado; aquí se cifra un flujo de bytes cualquiera (HTTP, RTSP).
nonisolated struct CanalHAP {
    static let bloque = 1024
    private let enviar: SymmetricKey
    private let recibir: SymmetricKey
    private var contadorEnvio: UInt64 = 0
    private var contadorRecibo: UInt64 = 0

    init(enviar: SymmetricKey, recibir: SymmetricKey) {
        self.enviar = enviar
        self.recibir = recibir
    }

    /// Llaves de un canal a partir del secreto de la verificación. AirPlay
    /// usa sal e información distintas para cada conexión.
    init(secreto: Data, sal: String, infoEnviar: String, infoRecibir: String) {
        self.init(
            enviar: HAP.derivar(secreto, sal: sal, info: infoEnviar),
            recibir: HAP.derivar(secreto, sal: sal, info: infoRecibir)
        )
    }

    mutating func cifrar(_ claro: Data) throws -> Data {
        var salida = Data()
        var i = claro.startIndex
        repeat {
            let fin = min(i + CanalHAP.bloque, claro.endIndex)
            let trozo = claro[i..<fin]
            let largo = withUnsafeBytes(of: UInt16(trozo.count).littleEndian, Array.init)
            let caja = try ChaChaPoly.seal(trozo, using: enviar, nonce: Self.nonce(contadorEnvio), authenticating: Data(largo))
            contadorEnvio += 1
            salida.append(contentsOf: largo)
            salida.append(caja.ciphertext)
            salida.append(caja.tag)
            i = fin
        } while i < claro.endIndex
        return salida
    }

    /// Descifra los bloques completos del búfer y deja ahí lo que llegó a medias.
    mutating func descifrar(_ bufer: inout Data) throws -> Data {
        var claro = Data()
        while bufer.count >= 2 {
            let i = bufer.startIndex
            let largo = Int(bufer[i]) | Int(bufer[i + 1]) << 8
            guard bufer.count >= 2 + largo + 16 else { break }
            let cifrado = bufer.subdata(in: (i + 2)..<(i + 2 + largo))
            let etiqueta = bufer.subdata(in: (i + 2 + largo)..<(i + 2 + largo + 16))
            let caja = try ChaChaPoly.SealedBox(nonce: Self.nonce(contadorRecibo), ciphertext: cifrado, tag: etiqueta)
            claro.append(try ChaChaPoly.open(caja, using: recibir, authenticating: bufer.subdata(in: i..<(i + 2))))
            contadorRecibo += 1
            bufer.removeSubrange(i..<(i + 2 + largo + 16))
        }
        return claro
    }

    /// Cuatro ceros y el contador en 8 bytes little endian.
    static func nonce(_ n: UInt64) -> ChaChaPoly.Nonce {
        try! ChaChaPoly.Nonce(data: [0, 0, 0, 0] + withUnsafeBytes(of: n.littleEndian, Array.init))
    }
}
