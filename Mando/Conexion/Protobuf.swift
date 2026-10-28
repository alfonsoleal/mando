import Foundation

/// Lo justo de Protocol Buffers para el control de Google TV: escribir y leer
/// varints y campos con longitud. Una biblioteca entera de protobuf para seis
/// mensajes sería más código que mantener que el que ahorra.
nonisolated struct Protobuf {
    private(set) var datos = Data()

    init() {}

    mutating func entero(_ campo: Int, _ valor: UInt64) {
        Protobuf.varint(UInt64(campo << 3), en: &datos)
        Protobuf.varint(valor, en: &datos)
    }

    mutating func entero(_ campo: Int, _ valor: Int) { entero(campo, UInt64(valor)) }
    mutating func booleano(_ campo: Int, _ valor: Bool) { entero(campo, valor ? 1 : 0) }

    mutating func bytes(_ campo: Int, _ valor: Data) {
        Protobuf.varint(UInt64(campo << 3 | 2), en: &datos)
        Protobuf.varint(UInt64(valor.count), en: &datos)
        datos.append(valor)
    }

    mutating func texto(_ campo: Int, _ valor: String) { bytes(campo, Data(valor.utf8)) }

    /// Un double (tipo fijo de 64 bits): el MRP mide tiempos y tamaños así.
    mutating func doble(_ campo: Int, _ valor: Double) {
        Protobuf.varint(UInt64(campo << 3 | 1), en: &datos)
        withUnsafeBytes(of: valor.bitPattern.littleEndian) { datos.append(contentsOf: $0) }
    }

    mutating func mensaje(_ campo: Int, _ armar: (inout Protobuf) -> Void) {
        var interno = Protobuf()
        armar(&interno)
        bytes(campo, interno.datos)
    }

    static func varint(_ valor: UInt64, en datos: inout Data) {
        var v = valor
        while v >= 0x80 {
            datos.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        datos.append(UInt8(v))
    }

    /// Lee un varint desde `i` y avanza. Nil si los datos se acaban antes.
    static func leerVarint(_ datos: Data, _ i: inout Data.Index) -> UInt64? {
        var resultado: UInt64 = 0
        var corrimiento: UInt64 = 0
        while i < datos.endIndex {
            let b = datos[i]
            i += 1
            resultado |= UInt64(b & 0x7F) << corrimiento
            if b & 0x80 == 0 { return resultado }
            corrimiento += 7
            if corrimiento > 63 { return nil }
        }
        return nil
    }

    /// Los campos de un mensaje, en orden, incluidos los de tipo fijo (el MRP
    /// manda duración y posición como double y la velocidad como float).
    static func campos(_ datos: Data) -> Campos {
        var resultado: [(Int, Valor)] = []
        var i = datos.startIndex
        while i < datos.endIndex, let llave = leerVarint(datos, &i) {
            let campo = Int(llave >> 3)
            switch llave & 7 {
            case 0:
                guard let v = leerVarint(datos, &i) else { return Campos(lista: resultado) }
                resultado.append((campo, .entero(v)))
            case 2:
                guard let n = leerVarint(datos, &i), i + Int(n) <= datos.endIndex else { return Campos(lista: resultado) }
                resultado.append((campo, .bytes(datos.subdata(in: i..<(i + Int(n))))))
                i += Int(n)
            case 1:
                guard i + 8 <= datos.endIndex else { return Campos(lista: resultado) }
                let v = datos[i..<(i + 8)].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                resultado.append((campo, .fijo64(v)))
                i += 8
            case 5:
                guard i + 4 <= datos.endIndex else { return Campos(lista: resultado) }
                let v = datos[i..<(i + 4)].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                resultado.append((campo, .fijo32(v)))
                i += 4
            default: return Campos(lista: resultado)
            }
        }
        return Campos(lista: resultado)
    }

    struct Campos {
        let lista: [(campo: Int, valor: Valor)]
        /// El primer valor de ese número de campo, si viene.
        subscript(campo: Int) -> Valor? { lista.first { $0.campo == campo }?.valor }
        /// Todos los valores de un campo repetido.
        func todos(_ campo: Int) -> [Valor] { lista.filter { $0.campo == campo }.map(\.valor) }
        var numeros: [Int] { lista.map(\.campo) }
    }

    enum Valor {
        case entero(UInt64)
        case bytes(Data)
        case fijo64(UInt64)
        case fijo32(UInt32)

        var entero: UInt64? { if case .entero(let v) = self { v } else { nil } }
        var bytes: Data? { if case .bytes(let d) = self { d } else { nil } }
        var texto: String? { bytes.map { String(decoding: $0, as: UTF8.self) } }
        var doble: Double? { if case .fijo64(let v) = self { Double(bitPattern: v) } else { nil } }
        var flotante: Float? { if case .fijo32(let v) = self { Float(bitPattern: v) } else { nil } }
    }
}

/// Los dos sockets del control de Google TV mandan cada mensaje precedido de
/// su longitud en varint.
nonisolated enum Marco {
    static func envolver(_ mensaje: Data) -> Data {
        var datos = Data()
        Protobuf.varint(UInt64(mensaje.count), en: &datos)
        datos.append(mensaje)
        return datos
    }

    static func extraer(de bufer: inout Data) -> [Data] {
        var mensajes: [Data] = []
        while true {
            var i = bufer.startIndex
            guard let n = Protobuf.leerVarint(bufer, &i), i + Int(n) <= bufer.endIndex else { break }
            mensajes.append(bufer.subdata(in: i..<(i + Int(n))))
            bufer.removeSubrange(bufer.startIndex..<(i + Int(n)))
        }
        return mensajes
    }
}
