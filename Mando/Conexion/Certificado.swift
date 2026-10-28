import Foundation
import Security

/// El certificado con el que este teléfono se presenta ante el Google TV. La
/// tele recuerda el certificado al emparejar: si cambia, hay que volver a
/// emparejar, por eso se crea una sola vez y se guarda en el Llavero.
///
/// iOS no trae una función para crear certificados, así que el X.509 se arma
/// a mano en DER y se firma con la llave de Security.framework.
nonisolated enum Certificado {
    struct Error: LocalizedError {
        let errorDescription: String?
    }

    /// La identidad (certificado + llave privada) con ese nombre. Si no existe
    /// en el Llavero, la crea.
    static func identidad(nombre: String) throws -> SecIdentity {
        if let existente = buscar(nombre) { return existente }
        try crear(nombre)
        guard let nueva = buscar(nombre) else {
            throw Error(errorDescription: "No pude guardar el certificado en el Llavero. Reinicia la app; si sigue, borra Mando y vuelve a instalarla.")
        }
        return nueva
    }

    static func borrar(nombre: String) {
        SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrLabel: nombre] as CFDictionary)
        SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: Data(nombre.utf8)] as CFDictionary)
    }

    /// Módulo y exponente de una llave RSA pública, sin ceros a la izquierda:
    /// así los usa el código de emparejamiento de Google.
    static func numeros(de llave: SecKey) -> (modulo: Data, exponente: Data)? {
        guard let der = SecKeyCopyExternalRepresentation(llave, nil) as Data? else { return nil }
        // PKCS#1: SEQUENCE { INTEGER módulo, INTEGER exponente }
        var i = der.startIndex
        guard DER.leerEncabezado(der, &i, tipo: 0x30) != nil,
              let m = DER.leerEncabezado(der, &i, tipo: 0x02) else { return nil }
        let modulo = der.subdata(in: i..<(i + m)); i += m
        guard let e = DER.leerEncabezado(der, &i, tipo: 0x02) else { return nil }
        let exponente = der.subdata(in: i..<(i + e))
        return (sinCeros(modulo), sinCeros(exponente))
    }

    static func llavePublica(de identidad: SecIdentity) -> SecKey? {
        var cert: SecCertificate?
        SecIdentityCopyCertificate(identidad, &cert)
        return cert.flatMap(SecCertificateCopyKey)
    }

    // MARK: - Privado

    private static func buscar(_ nombre: String) -> SecIdentity? {
        var resultado: CFTypeRef?
        let consulta: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecAttrLabel: nombre,
            kSecReturnRef: true,
        ]
        guard SecItemCopyMatching(consulta as CFDictionary, &resultado) == errSecSuccess else { return nil }
        return (resultado as! SecIdentity)
    }

    private static func crear(_ nombre: String) throws {
        borrar(nombre: nombre)
        let atributos: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048,
            kSecPrivateKeyAttrs: [
                kSecAttrIsPermanent: true,
                kSecAttrApplicationTag: Data(nombre.utf8),
                kSecAttrLabel: nombre,
            ] as [CFString: Any],
        ]
        var error: Unmanaged<CFError>?
        guard let privada = SecKeyCreateRandomKey(atributos as CFDictionary, &error),
              let publica = SecKeyCopyPublicKey(privada),
              let pkcs1 = SecKeyCopyExternalRepresentation(publica, &error) as Data? else {
            throw Error(errorDescription: "No pude crear la llave del certificado: \(error?.takeRetainedValue().localizedDescription ?? "sin detalle").")
        }

        let tbs = certificadoSinFirmar(nombre: nombre, pkcs1: pkcs1)
        guard let firma = SecKeyCreateSignature(privada, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, &error) as Data? else {
            throw Error(errorDescription: "No pude firmar el certificado.")
        }
        var bits = Data([0]); bits.append(firma)
        let der = DER.secuencia([tbs, DER.algoritmoSHA256RSA, DER.elemento(0x03, bits)])

        guard let cert = SecCertificateCreateWithData(nil, der as CFData) else {
            throw Error(errorDescription: "El certificado que armé no es válido.")
        }
        let estado = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: cert, kSecAttrLabel: nombre] as CFDictionary, nil)
        guard estado == errSecSuccess || estado == errSecDuplicateItem else {
            throw Error(errorDescription: "El Llavero no aceptó el certificado (código \(estado)).")
        }
    }

    private static func certificadoSinFirmar(nombre: String, pkcs1: Data) -> Data {
        let nombreX509 = DER.secuencia([
            DER.elemento(0x31, DER.secuencia([
                DER.oid([0x55, 0x04, 0x03]), // commonName
                DER.elemento(0x0C, Data(nombre.utf8)),
            ])),
        ])
        let ahora = Date()
        var bits = Data([0]); bits.append(pkcs1)
        let llave = DER.secuencia([
            DER.secuencia([DER.oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]), DER.nulo]),
            DER.elemento(0x03, bits),
        ])
        return DER.secuencia([
            DER.elemento(0xA0, DER.entero(Data([2]))), // versión 3
            DER.entero(Data((0..<8).map { _ in UInt8.random(in: 1...0x7F) })),
            DER.algoritmoSHA256RSA,
            nombreX509,
            DER.secuencia([DER.fecha(ahora.addingTimeInterval(-86_400)), DER.fecha(ahora.addingTimeInterval(20 * 365 * 86_400))]),
            nombreX509,
            llave,
        ])
    }

    private static func sinCeros(_ d: Data) -> Data {
        Data(d.drop(while: { $0 == 0 }))
    }
}

/// Lo mínimo de DER para armar y leer un certificado.
nonisolated enum DER {
    static func elemento(_ tipo: UInt8, _ contenido: Data) -> Data {
        var d = Data([tipo])
        let n = contenido.count
        if n < 0x80 {
            d.append(UInt8(n))
        } else {
            let bytes = withUnsafeBytes(of: UInt32(n).bigEndian, Array.init).drop(while: { $0 == 0 })
            d.append(0x80 | UInt8(bytes.count))
            d.append(contentsOf: bytes)
        }
        d.append(contenido)
        return d
    }

    static func secuencia(_ partes: [Data]) -> Data { elemento(0x30, partes.reduce(Data(), +)) }
    static func entero(_ d: Data) -> Data { elemento(0x02, d) }
    static func oid(_ bytes: [UInt8]) -> Data { elemento(0x06, Data(bytes)) }
    static let nulo = Data([0x05, 0x00])
    static let algoritmoSHA256RSA = secuencia([oid([0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]), nulo])

    static func fecha(_ fecha: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return elemento(0x17, Data(f.string(from: fecha).utf8))
    }

    /// Lee tipo y longitud, deja `i` al inicio del contenido y regresa la longitud.
    static func leerEncabezado(_ d: Data, _ i: inout Data.Index, tipo: UInt8) -> Int? {
        guard i + 2 <= d.endIndex, d[i] == tipo else { return nil }
        i += 1
        var n = Int(d[i]); i += 1
        if n & 0x80 != 0 {
            let cuantos = n & 0x7F
            guard i + cuantos <= d.endIndex else { return nil }
            n = d[i..<(i + cuantos)].reduce(0) { $0 << 8 | Int($1) }
            i += cuantos
        }
        return i + n <= d.endIndex ? n : nil
    }
}
