import CryptoKit
import Foundation

/// SRP-6a, el lado del teléfono, con el grupo de 3072 bits del RFC 5054 y
/// SHA-512: lo que usa el emparejamiento de Apple (HAP). El PIN que muestra
/// el Apple TV nunca viaja; los dos lados prueban que lo conocen.
nonisolated struct SRPCliente {
    static let usuario = "Pair-Setup"

    static let grupo = Modulo(EnteroGrande(Data(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74\
        020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437\
        4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED\
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05\
        98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB\
        9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B\
        E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718\
        3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33\
        A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7\
        ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864\
        D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2\
        08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
        """)!))
    static let g = EnteroGrande(5)
    static var largo: Int { (grupo.n.anchoEnBits + 7) / 8 }

    let privada: EnteroGrande
    let publica: EnteroGrande

    /// `privada` sólo se pasa en las pruebas, para comparar contra valores
    /// calculados por fuera.
    init(privada: Data? = nil) {
        let a = EnteroGrande(privada ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        self.privada = a
        publica = SRPCliente.grupo.potencia(SRPCliente.g, a)
    }

    struct Resultado {
        /// A, para mandar al Apple TV.
        let publica: Data
        /// M1, la prueba de que conocemos el PIN.
        let prueba: Data
        /// K, la llave de sesión: de ella salen las llaves de cifrado.
        let llave: Data
        /// La M2 que debe mandar el Apple TV si de verdad conoce el PIN.
        let pruebaEsperada: Data
    }

    /// Con la sal y la B que mandó el Apple TV y el PIN que se ve en la tele.
    /// Nil si B no sirve (cero módulo N): un servidor que manda eso miente.
    func calcular(sal: Data, publicaServidor bDatos: Data, pin: String) -> Resultado? {
        let grupo = SRPCliente.grupo
        let n = grupo.n
        let b = EnteroGrande(bDatos)
        guard b < n, !b.esCero else { return nil }

        let largo = SRPCliente.largo
        let k = EnteroGrande(H(n.bytes(), SRPCliente.g.bytes(longitud: largo)))
        let u = EnteroGrande(H(publica.bytes(longitud: largo), b.bytes(longitud: largo)))
        guard !u.esCero else { return nil }
        let x = EnteroGrande(H(sal, H(Data("\(SRPCliente.usuario):\(pin)".utf8))))

        // S = (B − k·gˣ)^(a + u·x) mod N
        let kv = grupo.multiplicar(k < n ? k : k - n, grupo.potencia(SRPCliente.g, x))
        let base = grupo.restar(b, kv)
        let s = grupo.potencia(base, privada + u * x)
        let llave = H(s.bytes())

        let hN = H(n.bytes())
        let hg = H(SRPCliente.g.bytes())
        let xor = Data(zip(hN, hg).map { $0 ^ $1 })
        let m1 = H(xor, H(Data(SRPCliente.usuario.utf8)), sal, publica.bytes(), b.bytes(), llave)
        let m2 = H(publica.bytes(), m1, llave)
        return Resultado(publica: publica.bytes(), prueba: m1, llave: llave, pruebaEsperada: m2)
    }
}

/// SHA-512 de varias piezas pegadas.
nonisolated func H(_ partes: Data...) -> Data {
    var sha = SHA512()
    for p in partes { sha.update(data: p) }
    return Data(sha.finalize())
}
