import Foundation
import Testing
@testable import Mando

/// SRP contra valores calculados por fuera, en Python con sus enteros nativos
/// (`scratchpad/srp/referencia.py` de la sesión donde se escribió): si la
/// aritmética grande tuviera un error, el Apple TV real rechazaría el PIN sin
/// decir por qué. Aquí se nota antes.
struct PruebasSRP {
    static let sal = Data(0..<16)
    static let privadaCliente = Data(1...32)
    static let B = Data(hex: "dd19fc089588ded8650dbbd3f5708b0fb0403ce3fef6d05cfb6d76ca84550a8bb65dfb4db29141c467dd573c171ac7077b3f677d1fd5f1619c03f6a66940d93af0e06cd9d175ebb1aac0e20f5ebddf8b3a5a400a8849e6e329b4730dbea45203d2d3704155ff0c75f6b67351945cd75a140ef18bb7b796cd8d0517b30399be50c642041b15759baaa65c38d5c59a9707094850e87f146859addda1bc952e087a2ac7a6705d5098809db367d7ab6984a27af0894ac249f34c96d41ce0043e6c60a5010ae9dab2d58831f683154d8d75fb95ddf384407ffc3bbd7b69f5e4a818f94d8476042bd9c3b56495c708d74f0622260e01209d551e43e1ca256e67ab2531d80676d6f3b25c2e8343f066ed6c99cec0b1e83e4b59106d0c98fabdec2a82bf00b98d759847263fa6b5fd44239eb2d01ff0e159ce477a2aac338d30a1030af816ccf408d3f3dfc113b0c5b22a6b39d27fed53793c104beccf80b15f1baa77271dd5dc09e8b89ea8723d36a4ebb1ab2ed5a001746fa4f49c086cbec3bc713503")!

    @Test func coincideConLaReferenciaDePython() throws {
        let cliente = SRPCliente(privada: Self.privadaCliente)
        let r = try #require(cliente.calcular(sal: Self.sal, publicaServidor: Self.B, pin: "1234"))

        #expect(r.publica.hex == "bc0e7cf5dc3babf67dcedbb3b140aacc6cac43f4336b43bbd5de48d6ea7c8eda66924e354255225bccad9debe21182e6bb050f3ff3e6cfbb62c229379968c70ca436ad649a0b051373184215eef046f6f1f2256838f958581f6c7b2b85fa4afe326a0e8a951d4489305331aff88a136fd8d108bcc95fceb7e557c889c828bd23fb0702f053e1ca6470fb3c76bce4843fc005c7ea675740f8550212656cfc8919d9db805a434a68229e0d9dfe43fc16dc680a5ce74b77cf374353b05759bc1da3a9dabde30a4209381c87ca83d9483abdf66b86f9b1cbda9ad82c62712b87ce6fb7069b8fc8df344261821a06d0dc5106af76d4245f3f7737a94dbc484b415555dc401842d3011204553ba9f611b02bc38de26eba1a76bf8350205a62c436ba1c3c7c69d59318bd107fd1c1f5d846b3142e85a5d49e522655e020ed1bfe1e186cf923bf328f0b9b4c6a8aa3266ed9125bb98d63827110713be7803122ee4603c54ea31863ce4b10aff31f9073cf63b94733b4f066e72d4ec35687047d5d0db160")
        #expect(r.llave.hex == "831091bee15bd8f802c43c24c8016a731f164f17ff59d3cc0b6824f93d8e55e7fa7c8b58579148ca917ade62e2f49972352ac51d941838baa43e1af257b19b9c")
        #expect(r.prueba.hex == "0fb6671b51cb8033e019e294f4cf1cec46fced03efbc366f9b01e7ba2ff166405f090d89959f6c0ec9d3f32149a1f4792f55c2c526222a604ee52d4e343e1744")
        #expect(r.pruebaEsperada.hex == "1b1cb8df573e9770c17dd2ae42ec4862a397cb5657431dea78433075122635796c7e3cf9ed3886faa0256d66dcffc3a6e1a01a0117c3e66ccfb023e09a90f616")
    }

    @Test func otroPinDaOtraPrueba() throws {
        let cliente = SRPCliente(privada: Self.privadaCliente)
        let bueno = try #require(cliente.calcular(sal: Self.sal, publicaServidor: Self.B, pin: "1234"))
        let malo = try #require(cliente.calcular(sal: Self.sal, publicaServidor: Self.B, pin: "1235"))
        #expect(bueno.prueba != malo.prueba)
    }

    @Test func rechazaUnaBQueNoSirve() {
        let cliente = SRPCliente()
        #expect(cliente.calcular(sal: Self.sal, publicaServidor: Data([0]), pin: "1234") == nil)
        #expect(cliente.calcular(sal: Self.sal, publicaServidor: SRPCliente.grupo.n.bytes(), pin: "1234") == nil)
    }

    @Test func aritmeticaBasica() {
        let a = EnteroGrande(Data(hex: "ffffffffffffffffffff")!)
        let b = EnteroGrande(1)
        #expect((a + b).bytes().hex == "0100000000000000000000")
        #expect(((a + b) - b) == a)
        #expect((a * a).bytes().hex == "fffffffffffffffffffe00000000000000000001")
        let m = Modulo(EnteroGrande(1_000_003))
        #expect(m.potencia(EnteroGrande(2), EnteroGrande(100)) == EnteroGrande(UInt64(powmod(2, 100, 1_000_003))))
        #expect(m.multiplicar(EnteroGrande(999_999), EnteroGrande(999_998)) == EnteroGrande(UInt64(999_999 * 999_998 % 1_000_003)))
    }

    private func powmod(_ b: UInt64, _ e: UInt64, _ m: UInt64) -> UInt64 {
        var r: UInt64 = 1, b = b % m, e = e
        while e > 0 {
            if e & 1 == 1 { r = r * b % m }
            b = b * b % m
            e >>= 1
        }
        return r
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
