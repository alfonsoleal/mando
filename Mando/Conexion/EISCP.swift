import Foundation

/// El formato de eISCP, el protocolo de red de los receptores Onkyo (y Pioneer
/// e Integra desde 2016): un encabezado de 16 bytes y un mensaje ISCP de texto,
/// por ejemplo `!1MVL20` (volumen a 32, en hexadecimal).
nonisolated enum EISCP {
    static let puerto: UInt16 = 60128

    /// Arma el paquete de un comando como `PWR01`.
    static func paquete(_ comando: String) -> Data {
        let mensaje = Data("!1\(comando)\r".utf8)
        var datos = Data("ISCP".utf8)
        datos.append(contentsOf: bigEndian(UInt32(16)))
        datos.append(contentsOf: bigEndian(UInt32(mensaje.count)))
        datos.append(contentsOf: [0x01, 0x00, 0x00, 0x00])
        datos.append(mensaje)
        return datos
    }

    /// Saca los mensajes completos del búfer y deja ahí lo que llegó a medias:
    /// TCP no respeta los límites de los paquetes y un mensaje puede llegar en
    /// dos lecturas, o dos mensajes en una.
    static func extraer(de bufer: inout Data) -> [String] {
        var mensajes: [String] = []
        while bufer.count >= 16 {
            guard bufer.prefix(4) == Data("ISCP".utf8) else {
                // Basura al inicio: se descarta hasta la siguiente firma.
                if let firma = bufer.range(of: Data("ISCP".utf8)) {
                    bufer.removeSubrange(bufer.startIndex..<firma.lowerBound)
                    continue
                }
                bufer.removeAll()
                break
            }
            let inicio = bufer.startIndex
            let encabezado = Int(entero(bufer, desde: inicio + 4))
            let tamano = Int(entero(bufer, desde: inicio + 8))
            guard bufer.count >= encabezado + tamano else { break }
            let cuerpo = bufer.subdata(in: (inicio + encabezado)..<(inicio + encabezado + tamano))
            bufer.removeSubrange(inicio..<(inicio + encabezado + tamano))
            if let texto = String(data: cuerpo, encoding: .utf8) {
                // Los receptores cierran con EOF (0x1A) y CR/LF según el modelo.
                let limpio = texto.trimmingCharacters(in: CharacterSet(charactersIn: "\u{1A}\r\n"))
                if limpio.hasPrefix("!1") { mensajes.append(String(limpio.dropFirst(2))) }
            }
        }
        return mensajes
    }

    /// Traduce una orden de la app a comandos ISCP. Varias órdenes no existen
    /// en un receptor (flechas, apps) y regresan vacío.
    static func comandos(para orden: Orden) -> [String] {
        switch orden {
        case .encender(let si): [si ? "PWR01" : "PWR00"]
        case .subirVolumen: ["MVLUP"]
        case .bajarVolumen: ["MVLDOWN"]
        case .volumen(let v): ["MVL" + hex(min(max(v, 0), 80))]
        case .silencio(let si): [si ? "AMT01" : "AMT00"]
        case .entrada(let clave): ["SLI" + clave]
        case .modoSonido(let clave): ["LMD" + clave]
        default: []
        }
    }

    /// Lo que se le pregunta al receptor al conectar para pintar su estado real.
    static let preguntas = ["PWRQSTN", "MVLQSTN", "AMTQSTN", "SLIQSTN", "LMDQSTN"]

    /// Interpreta lo que reporta el receptor. Lo que no sirve a la app
    /// (información de red, de la zona 2, del sintonizador) se ignora.
    static func reporte(de mensaje: String) -> Reporte? {
        guard mensaje.count >= 3 else { return nil }
        let codigo = String(mensaje.prefix(3))
        let valor = String(mensaje.dropFirst(3))
        // «N/A» es la respuesta cuando el receptor está apagado.
        guard valor != "N/A" else { return nil }
        switch codigo {
        case "PWR": return .encendido(valor == "01")
        case "AMT": return .silencio(valor == "01")
        case "MVL": return Int(valor, radix: 16).map { .volumen($0) }
        case "SLI": return .entrada(valor)
        case "LMD": return .modoSonido(valor)
        default: return nil
        }
    }

    private static func hex(_ n: Int) -> String {
        String(format: "%02X", n)
    }

    private static func bigEndian(_ n: UInt32) -> [UInt8] {
        withUnsafeBytes(of: n.bigEndian, Array.init)
    }

    private static func entero(_ datos: Data, desde i: Data.Index) -> UInt32 {
        datos[i..<(i + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
