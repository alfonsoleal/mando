import Foundation

/// OPACK, el formato binario de Apple para los mensajes de Companion: como
/// JSON pero en bytes, con enteros, textos y diccionarios cortos de un solo
/// byte de encabezado. No está documentado; la tabla de tipos sale de pyatv.
nonisolated indirect enum OPACK: Equatable, Sendable {
    case nulo
    case booleano(Bool)
    case entero(Int64)
    case real(Double)
    case texto(String)
    case datos(Data)
    case uuid(UUID)
    case lista([OPACK])
    case diccionario([(OPACK, OPACK)])

    static func == (a: OPACK, b: OPACK) -> Bool {
        switch (a, b) {
        case (.nulo, .nulo): true
        case let (.booleano(x), .booleano(y)): x == y
        case let (.entero(x), .entero(y)): x == y
        case let (.real(x), .real(y)): x == y
        case let (.texto(x), .texto(y)): x == y
        case let (.datos(x), .datos(y)): x == y
        case let (.uuid(x), .uuid(y)): x == y
        case let (.lista(x), .lista(y)): x == y
        case let (.diccionario(x), .diccionario(y)):
            x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: false
        }
    }

    /// Un diccionario con llaves de texto, que es como vienen todos los
    /// mensajes de Companion.
    static func dic(_ pares: KeyValuePairs<String, OPACK>) -> OPACK {
        .diccionario(pares.map { (.texto($0.key), $0.value) })
    }

    subscript(_ llave: String) -> OPACK? {
        guard case .diccionario(let pares) = self else { return nil }
        return pares.first { $0.0 == .texto(llave) }?.1
    }

    var texto: String? { if case .texto(let t) = self { t } else { nil } }
    var datos: Data? { if case .datos(let d) = self { d } else { nil } }
    var entero: Int64? { if case .entero(let n) = self { n } else { nil } }

    // MARK: - Escribir

    var empacado: Data {
        var d = Data()
        escribir(en: &d)
        return d
    }

    private func escribir(en d: inout Data) {
        switch self {
        case .nulo: d.append(0x04)
        case .booleano(let si): d.append(si ? 0x01 : 0x02)
        case .uuid(let u):
            d.append(0x05)
            d.append(contentsOf: withUnsafeBytes(of: u.uuid, Array.init))
        case .entero(let n):
            if n >= 0 && n <= 0x27 { d.append(0x08 + UInt8(n)) }
            else if n >= 0 && n <= 0xFF { d.append(0x30); d.append(UInt8(n)) }
            else if n >= 0 && n <= 0xFFFF { d.append(0x31); OPACK.le(UInt64(n), 2, &d) }
            else if n >= 0 && n <= 0xFFFF_FFFF { d.append(0x32); OPACK.le(UInt64(n), 4, &d) }
            else { d.append(0x33); OPACK.le(UInt64(bitPattern: n), 8, &d) }
        case .real(let x):
            d.append(0x36)
            OPACK.le(x.bitPattern, 8, &d)
        case .texto(let t):
            let b = Data(t.utf8)
            OPACK.encabezado(b.count, corto: 0x40, largos: [0x61, 0x62, 0x63, 0x64], tamanos: [1, 2, 3, 4], &d)
            d.append(b)
        case .datos(let b):
            OPACK.encabezado(b.count, corto: 0x70, largos: [0x91, 0x92, 0x93, 0x94], tamanos: [1, 2, 4, 8], &d)
            d.append(b)
        case .lista(let l):
            d.append(0xD0 + UInt8(min(l.count, 0xF)))
            l.forEach { $0.escribir(en: &d) }
            if l.count >= 0xF { d.append(0x03) }
        case .diccionario(let p):
            d.append(0xE0 + UInt8(min(p.count, 0xF)))
            for (k, v) in p { k.escribir(en: &d); v.escribir(en: &d) }
            if p.count >= 0xF { d.append(0x03) }
        }
    }

    private static func encabezado(_ n: Int, corto: UInt8, largos: [UInt8], tamanos: [Int], _ d: inout Data) {
        if n <= 0x20 { d.append(corto + UInt8(n)); return }
        for (marca, tam) in zip(largos, tamanos) where tam == 8 || n < 1 << (tam * 8) {
            d.append(marca)
            le(UInt64(n), tam, &d)
            return
        }
    }

    private static func le(_ n: UInt64, _ bytes: Int, _ d: inout Data) {
        for i in 0..<bytes { d.append(UInt8(truncatingIfNeeded: n >> (8 * UInt64(i)))) }
    }

    // MARK: - Leer

    struct Error: Swift.Error {}

    static func desempacar(_ datos: Data) throws -> OPACK {
        var lector = Lector(datos: datos)
        return try lector.valor()
    }

    private struct Lector {
        let datos: Data
        var i: Data.Index
        /// Los valores ya leídos: OPACK repite un texto o unos bytes con un
        /// byte que apunta aquí en vez de volver a escribirlos.
        var vistos: [OPACK] = []

        init(datos: Data) {
            self.datos = datos
            i = datos.startIndex
        }

        mutating func byte() throws -> UInt8 {
            guard i < datos.endIndex else { throw Error() }
            defer { i += 1 }
            return datos[i]
        }

        mutating func tomar(_ n: Int) throws -> Data {
            guard n >= 0, i + n <= datos.endIndex else { throw Error() }
            defer { i += n }
            return datos.subdata(in: i..<(i + n))
        }

        mutating func le(_ n: Int) throws -> UInt64 {
            try tomar(n).reversed().reduce(0) { $0 << 8 | UInt64($1) }
        }

        mutating func valor() throws -> OPACK {
            let t = try byte()
            var guardar = true
            let v: OPACK
            switch t {
            case 0x01: v = .booleano(true); guardar = false
            case 0x02: v = .booleano(false); guardar = false
            case 0x04: v = .nulo; guardar = false
            case 0x05:
                let b = try tomar(16)
                v = .uuid(UUID(uuid: b.withUnsafeBytes { $0.loadUnaligned(as: uuid_t.self) }))
            case 0x06: v = .real(Double(bitPattern: try le(8)))
            case 0x08...0x2F: v = .entero(Int64(t - 0x08)); guardar = false
            case 0x30: v = .entero(Int64(try le(1)))
            case 0x31: v = .entero(Int64(try le(2)))
            case 0x32: v = .entero(Int64(try le(4)))
            case 0x33: v = .entero(Int64(bitPattern: try le(8)))
            case 0x35: v = .real(Double(Float(bitPattern: UInt32(try le(4)))))
            case 0x36: v = .real(Double(bitPattern: try le(8)))
            case 0x40...0x60: v = try texto(Int(t - 0x40))
            case 0x61...0x64: v = try texto(Int(try le(Int(t - 0x60))))
            case 0x70...0x90: v = .datos(try tomar(Int(t - 0x70)))
            case 0x91...0x94: v = .datos(try tomar(Int(try le([1, 2, 4, 8][Int(t - 0x91)]))))
            case 0xA0...0xC0:
                let n = Int(t - 0xA0)
                guard n < vistos.count else { throw Error() }
                return vistos[n]
            case 0xC1...0xC4:
                let n = Int(try le(Int(t - 0xC0)))
                guard n < vistos.count else { throw Error() }
                return vistos[n]
            case 0xD0...0xDF:
                var l: [OPACK] = []
                let cuantos = Int(t & 0xF)
                while cuantos == 0xF ? datos[safe: i] != 0x03 : l.count < cuantos {
                    l.append(try valor())
                }
                if cuantos == 0xF { i += 1 }
                v = .lista(l); guardar = false
            case 0xE0...0xEF:
                var p: [(OPACK, OPACK)] = []
                let cuantos = Int(t & 0xF)
                while cuantos == 0xF ? datos[safe: i] != 0x03 : p.count < cuantos {
                    let k = try valor()
                    p.append((k, try valor()))
                }
                if cuantos == 0xF { i += 1 }
                v = .diccionario(p); guardar = false
            default:
                throw Error()
            }
            if guardar { vistos.append(v) }
            return v
        }

        mutating func texto(_ n: Int) throws -> OPACK {
            .texto(String(decoding: try tomar(n), as: UTF8.self))
        }
    }
}

private extension Data {
    nonisolated subscript(safe i: Index) -> UInt8? { i < endIndex ? self[i] : nil }
}

/// TLV8, el formato de los mensajes de emparejamiento: tipo, largo de un
/// byte y valor. Lo que pasa de 255 bytes se parte en trozos seguidos del
/// mismo tipo.
nonisolated enum TLV8 {
    static let metodo: UInt8 = 0x00
    static let identificador: UInt8 = 0x01
    static let sal: UInt8 = 0x02
    static let llavePublica: UInt8 = 0x03
    static let prueba: UInt8 = 0x04
    static let cifrado: UInt8 = 0x05
    static let estado: UInt8 = 0x06
    static let error: UInt8 = 0x07
    static let firma: UInt8 = 0x0A
    static let nombre: UInt8 = 0x11

    static func armar(_ pares: [(UInt8, Data)]) -> Data {
        var d = Data()
        for (tipo, valor) in pares {
            if valor.isEmpty { d.append(contentsOf: [tipo, 0]); continue }
            var i = valor.startIndex
            while i < valor.endIndex {
                let fin = min(i + 255, valor.endIndex)
                d.append(tipo)
                d.append(UInt8(fin - i))
                d.append(valor[i..<fin])
                i = fin
            }
        }
        return d
    }

    static func leer(_ d: Data) -> [UInt8: Data] {
        var resultado: [UInt8: Data] = [:]
        var i = d.startIndex
        var anterior: UInt8?
        while i + 2 <= d.endIndex {
            let tipo = d[i]
            let n = Int(d[i + 1])
            guard i + 2 + n <= d.endIndex else { break }
            let valor = d[(i + 2)..<(i + 2 + n)]
            if tipo == anterior { resultado[tipo, default: Data()].append(valor) }
            else { resultado[tipo] = Data(valor) }
            anterior = tipo
            i += 2 + n
        }
        return resultado
    }
}
