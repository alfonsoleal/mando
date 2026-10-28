import Foundation

/// Enteros sin signo de cualquier tamaño, lo justo para SRP: sumar, restar,
/// multiplicar y elevar a una potencia módulo un primo de 3072 bits. Swift no
/// trae enteros grandes y una biblioteca entera sería mucho para tres cuentas.
///
/// Los dígitos van en base 2³², del menos al más significativo.
nonisolated struct EnteroGrande: Equatable, Comparable, Sendable {
    fileprivate(set) var digitos: [UInt32]

    init(_ valor: UInt64 = 0) {
        digitos = [UInt32(truncatingIfNeeded: valor), UInt32(truncatingIfNeeded: valor >> 32)]
        normalizar()
    }

    /// Desde bytes en orden de red (el más significativo primero).
    init(_ bytes: Data) {
        var d: [UInt32] = []
        d.reserveCapacity(bytes.count / 4 + 1)
        var acumulado: UInt32 = 0
        var corrimiento: UInt32 = 0
        for b in bytes.reversed() {
            acumulado |= UInt32(b) << corrimiento
            corrimiento += 8
            if corrimiento == 32 {
                d.append(acumulado)
                acumulado = 0
                corrimiento = 0
            }
        }
        if corrimiento > 0 { d.append(acumulado) }
        digitos = d
        normalizar()
    }

    fileprivate init(digitos: [UInt32]) {
        self.digitos = digitos
        normalizar()
    }

    var esCero: Bool { digitos.isEmpty }

    /// En orden de red. Sin `longitud`, sin ceros a la izquierda; con ella,
    /// rellenado a ese largo (lo que SRP llama PAD).
    func bytes(longitud: Int? = nil) -> Data {
        var salida = Data()
        for d in digitos.reversed() {
            salida.append(contentsOf: [UInt8(d >> 24), UInt8(d >> 16 & 0xFF), UInt8(d >> 8 & 0xFF), UInt8(d & 0xFF)])
        }
        let sinCeros = salida.drop(while: { $0 == 0 })
        guard let longitud else { return Data(sinCeros) }
        return Data(repeating: 0, count: max(longitud - sinCeros.count, 0)) + sinCeros
    }

    var anchoEnBits: Int {
        guard let alto = digitos.last else { return 0 }
        return digitos.count * 32 - alto.leadingZeroBitCount
    }

    func bit(_ i: Int) -> Bool {
        let d = i / 32
        return d < digitos.count && digitos[d] >> UInt32(i % 32) & 1 == 1
    }

    static func < (a: EnteroGrande, b: EnteroGrande) -> Bool {
        if a.digitos.count != b.digitos.count { return a.digitos.count < b.digitos.count }
        for i in stride(from: a.digitos.count - 1, through: 0, by: -1) where a.digitos[i] != b.digitos[i] {
            return a.digitos[i] < b.digitos[i]
        }
        return false
    }

    static func + (a: EnteroGrande, b: EnteroGrande) -> EnteroGrande {
        let n = max(a.digitos.count, b.digitos.count)
        var r = [UInt32](repeating: 0, count: n + 1)
        var acarreo: UInt64 = 0
        for i in 0..<n {
            let s = UInt64(i < a.digitos.count ? a.digitos[i] : 0) + UInt64(i < b.digitos.count ? b.digitos[i] : 0) + acarreo
            r[i] = UInt32(truncatingIfNeeded: s)
            acarreo = s >> 32
        }
        r[n] = UInt32(acarreo)
        return EnteroGrande(digitos: r)
    }

    /// Sólo cuando a ≥ b: SRP nunca necesita negativos.
    static func - (a: EnteroGrande, b: EnteroGrande) -> EnteroGrande {
        precondition(!(a < b), "Resta con resultado negativo")
        var r = a.digitos
        var prestamo: Int64 = 0
        for i in 0..<r.count {
            var s = Int64(r[i]) - Int64(i < b.digitos.count ? b.digitos[i] : 0) - prestamo
            prestamo = 0
            if s < 0 { s += 1 << 32; prestamo = 1 }
            r[i] = UInt32(s)
        }
        return EnteroGrande(digitos: r)
    }

    static func * (a: EnteroGrande, b: EnteroGrande) -> EnteroGrande {
        guard !a.esCero, !b.esCero else { return EnteroGrande() }
        var r = [UInt32](repeating: 0, count: a.digitos.count + b.digitos.count)
        for i in 0..<a.digitos.count {
            var acarreo: UInt64 = 0
            let ai = UInt64(a.digitos[i])
            for j in 0..<b.digitos.count {
                let t = ai * UInt64(b.digitos[j]) + UInt64(r[i + j]) + acarreo
                r[i + j] = UInt32(truncatingIfNeeded: t)
                acarreo = t >> 32
            }
            r[i + b.digitos.count] = UInt32(acarreo)
        }
        return EnteroGrande(digitos: r)
    }

    private mutating func normalizar() {
        while digitos.last == 0 { digitos.removeLast() }
    }
}

/// Aritmética módulo un número impar con multiplicación de Montgomery: evita
/// dividir, que es lo caro, y hace que una potencia de 3072 bits tarde
/// milisegundos.
nonisolated struct Modulo: Sendable {
    let n: EnteroGrande
    private let digitosN: [UInt32]
    private let inversoN0: UInt32
    /// R² mod n, con R = 2^(32·dígitos). Convierte a la forma de Montgomery.
    private let r2: [UInt32]

    init(_ n: EnteroGrande) {
        precondition(n.bit(0), "El módulo de Montgomery tiene que ser impar")
        self.n = n
        digitosN = n.digitos
        // -n⁻¹ mod 2³² por Newton: cada vuelta duplica los bits correctos.
        var inv: UInt32 = 1
        for _ in 0..<5 { inv = inv &* (2 &- digitosN[0] &* inv) }
        inversoN0 = 0 &- inv

        // R² mod n doblando 1 tantas veces como bits tiene R², restando n
        // cada que se pasa. Se hace una sola vez por módulo.
        let s = digitosN.count
        var r = [UInt32](repeating: 0, count: s + 1)
        r[0] = 1
        for _ in 0..<(2 * 32 * s) {
            var acarreo: UInt32 = 0
            for i in 0..<r.count {
                let nuevo = r[i] >> 31
                r[i] = r[i] << 1 | acarreo
                acarreo = nuevo
            }
            if !Modulo.menor(r, que: digitosN) { Modulo.restar(&r, digitosN) }
        }
        r2 = Array(r.prefix(s))
    }

    /// a·b mod n. Ambos deben ser menores que n.
    func multiplicar(_ a: EnteroGrande, _ b: EnteroGrande) -> EnteroGrande {
        let am = mont(rellenar(a), r2)
        let p = mont(am, rellenar(b))
        return EnteroGrande(digitos: p)
    }

    /// base^exponente mod n, de izquierda a derecha.
    func potencia(_ base: EnteroGrande, _ exponente: EnteroGrande) -> EnteroGrande {
        let s = digitosN.count
        var uno = [UInt32](repeating: 0, count: s)
        uno[0] = 1
        var resultado = mont(uno, r2)
        let b = mont(rellenar(base), r2)
        for i in stride(from: exponente.anchoEnBits - 1, through: 0, by: -1) {
            resultado = mont(resultado, resultado)
            if exponente.bit(i) { resultado = mont(resultado, b) }
        }
        return EnteroGrande(digitos: mont(resultado, uno))
    }

    /// (a + b) mod n y (a − b) mod n, con a, b < n.
    func sumar(_ a: EnteroGrande, _ b: EnteroGrande) -> EnteroGrande {
        let s = a + b
        return s < n ? s : s - n
    }

    func restar(_ a: EnteroGrande, _ b: EnteroGrande) -> EnteroGrande {
        a < b ? (a + n) - b : a - b
    }

    // MARK: - Privado

    private func rellenar(_ a: EnteroGrande) -> [UInt32] {
        precondition(a < n, "El valor debe ser menor que el módulo")
        var d = a.digitos
        d.append(contentsOf: repeatElement(0, count: digitosN.count - d.count))
        return d
    }

    /// a·b·R⁻¹ mod n (CIOS). Los acumulados caben en 64 bits: el peor caso
    /// es (2³²−1) + (2³²−1)² + (2³²−1) = 2⁶⁴−1.
    private func mont(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        let s = digitosN.count
        var t = [UInt32](repeating: 0, count: s + 2)
        a.withUnsafeBufferPointer { a in
        b.withUnsafeBufferPointer { b in
        digitosN.withUnsafeBufferPointer { n in
        t.withUnsafeMutableBufferPointer { t in
            for i in 0..<s {
                var c: UInt64 = 0
                let bi = UInt64(b[i])
                for j in 0..<s {
                    let x = UInt64(t[j]) + UInt64(a[j]) * bi + c
                    t[j] = UInt32(truncatingIfNeeded: x)
                    c = x >> 32
                }
                var x = UInt64(t[s]) + c
                t[s] = UInt32(truncatingIfNeeded: x)
                t[s + 1] = UInt32(x >> 32)

                let m = UInt64(t[0] &* inversoN0)
                x = UInt64(t[0]) + m * UInt64(n[0])
                c = x >> 32
                for j in 1..<s {
                    x = UInt64(t[j]) + m * UInt64(n[j]) + c
                    t[j - 1] = UInt32(truncatingIfNeeded: x)
                    c = x >> 32
                }
                x = UInt64(t[s]) + c
                t[s - 1] = UInt32(truncatingIfNeeded: x)
                t[s] = t[s + 1] + UInt32(x >> 32)
            }
        }}}}
        var r = Array(t.prefix(s + 1))
        if !Modulo.menor(r, que: digitosN) { Modulo.restar(&r, digitosN) }
        return Array(r.prefix(s))
    }

    private static func menor(_ a: [UInt32], que b: [UInt32]) -> Bool {
        for i in stride(from: max(a.count, b.count) - 1, through: 0, by: -1) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    private static func restar(_ a: inout [UInt32], _ b: [UInt32]) {
        var prestamo: UInt64 = 0
        for i in 0..<a.count {
            let y = UInt64(i < b.count ? b[i] : 0) + prestamo
            let x = UInt64(a[i])
            if x >= y {
                a[i] = UInt32(x - y); prestamo = 0
            } else {
                a[i] = UInt32(x + (1 << 32) - y); prestamo = 1
            }
        }
    }
}
