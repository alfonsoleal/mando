import CryptoKit
import Foundation

/// Los mensajes del control remoto de Android TV / Google TV, versión 2: la
/// que usa la app oficial de Google Home. Dos puertos: 6467 para emparejar
/// (protocolo «polo») y 6466 para controlar. No hay documentación oficial; los
/// números de campo salen de los .proto que la comunidad reconstruyó
/// (androidtvremote2, el que usa Home Assistant).
nonisolated enum AndroidTV {
    static let puertoEmparejar: UInt16 = 6467
    static let puertoControl: UInt16 = 6466
    static let servicioBonjour = "_androidtvremote2._tcp"

    // MARK: - Emparejamiento

    enum Emparejar {
        /// La tele contesta 200 cuando todo va bien.
        static let ok = 200

        static func solicitud(cliente: String) -> Data {
            exterior { m in
                m.mensaje(10) { s in
                    s.texto(1, "atvremote")
                    s.texto(2, cliente)
                }
            }
        }

        /// Pedimos código hexadecimal de 6 y el papel de «entrada»: el teléfono
        /// escribe el código que muestra la tele, no al revés.
        static func opciones() -> Data {
            exterior { m in
                m.mensaje(20) { o in
                    o.mensaje(1) { c in c.entero(1, 3); c.entero(2, 6) }
                    o.entero(3, 1)
                }
            }
        }

        static func configuracion() -> Data {
            exterior { m in
                m.mensaje(30) { c in
                    c.mensaje(1) { e in e.entero(1, 3); e.entero(2, 6) }
                    c.entero(2, 1)
                }
            }
        }

        static func secreto(_ hash: Data) -> Data {
            exterior { m in m.mensaje(40) { s in s.bytes(1, hash) } }
        }

        /// Estado y qué campo trae la respuesta de la tele.
        static func leer(_ datos: Data) -> (estado: Int, campos: [Int]) {
            let c = Protobuf.campos(datos)
            return (Int(c[2]?.entero ?? 0), c.numeros)
        }

        /// El secreto que prueba que el usuario vio el código: SHA-256 de las
        /// dos llaves públicas y los últimos 4 caracteres del código. Los dos
        /// primeros son el primer byte de ese mismo hash, así que un código mal
        /// escrito se detecta aquí sin preguntarle a la tele.
        static func hash(
            codigo: String,
            cliente: (modulo: Data, exponente: Data),
            tele: (modulo: Data, exponente: Data)
        ) -> Data? {
            let limpio = codigo.uppercased().filter(\.isHexDigit)
            guard limpio.count == 6,
                  let control = UInt8(limpio.prefix(2), radix: 16),
                  let resto = Data(hex: String(limpio.dropFirst(2))) else { return nil }
            var sha = SHA256()
            sha.update(data: cliente.modulo)
            sha.update(data: cliente.exponente)
            sha.update(data: tele.modulo)
            sha.update(data: tele.exponente)
            sha.update(data: resto)
            let hash = Data(sha.finalize())
            return hash.first == control ? hash : nil
        }

        private static func exterior(_ armar: (inout Protobuf) -> Void) -> Data {
            var m = Protobuf()
            m.entero(1, 2)
            m.entero(2, ok)
            armar(&m)
            return m.datos
        }
    }

    // MARK: - Control

    enum Entrante: Equatable {
        case configurar
        case activar
        case ping(UInt64)
        case encendido(Bool)
        case volumen(nivel: Int, maximo: Int, silencio: Bool)
        case app(paquete: String)
        /// La tele abrió un campo de texto (o cambió su contenido). Trae los
        /// contadores que hay que repetir para escribir en ese campo.
        case campoDeTexto(ime: UInt64, campo: UInt64)
        case otro
    }

    static func leer(_ datos: Data) -> Entrante {
        let c = Protobuf.campos(datos)
        if c[1] != nil { return .configurar }
        if c[2] != nil { return .activar }
        if let ping = c[8]?.bytes {
            return .ping(Protobuf.campos(ping)[1]?.entero ?? 0)
        }
        if let inicio = c[40]?.bytes {
            return .encendido(Protobuf.campos(inicio)[1]?.entero == 1)
        }
        if let vol = c[50]?.bytes {
            let v = Protobuf.campos(vol)
            return .volumen(
                nivel: Int(v[7]?.entero ?? 0),
                maximo: Int(v[6]?.entero ?? 100),
                silencio: v[8]?.entero == 1
            )
        }
        if let edicion = c[21]?.bytes {
            let e = Protobuf.campos(edicion)
            return .campoDeTexto(ime: e[1]?.entero ?? 0, campo: e[2]?.entero ?? 0)
        }
        // Al abrir el teclado la tele manda el campo sin contador de IME.
        if let mostrar = c[22]?.bytes,
           let estado = Protobuf.campos(mostrar)[2]?.bytes {
            return .campoDeTexto(ime: 0, campo: Protobuf.campos(estado)[1]?.entero ?? 0)
        }
        // La tele avisa qué app está al frente dentro del aviso del teclado.
        if let ime = c[20]?.bytes,
           let info = Protobuf.campos(ime)[1]?.bytes,
           let paquete = Protobuf.campos(info)[12]?.bytes {
            return .app(paquete: String(decoding: paquete, as: UTF8.self))
        }
        return .otro
    }

    /// Se presenta como la app oficial; con otro código la tele no activa
    /// todas las funciones.
    static func configurar(modelo: String) -> Data {
        var m = Protobuf()
        m.mensaje(1) { c in
            c.entero(1, 622)
            c.mensaje(2) { d in
                d.texto(1, modelo)
                d.texto(2, "Mando")
                d.entero(3, 1)
                d.texto(4, "1")
                d.texto(5, "atvremote")
                d.texto(6, "1.0.0")
            }
        }
        return m.datos
    }

    static func activar() -> Data {
        var m = Protobuf()
        m.mensaje(2) { a in a.entero(1, 622) }
        return m.datos
    }

    static func pong(_ valor: UInt64) -> Data {
        var m = Protobuf()
        m.mensaje(9) { p in p.entero(1, valor) }
        return m.datos
    }

    /// Una tecla «corta»: bajar y subir en un solo mensaje.
    static func tecla(_ codigo: Int) -> Data {
        var m = Protobuf()
        m.mensaje(10) { k in k.entero(1, codigo); k.entero(2, 3) }
        return m.datos
    }

    /// Reemplaza todo el contenido del campo abierto en la tele con `texto` y
    /// deja el cursor al final. Se manda el texto completo cada vez, no letra
    /// por letra: así borrar en el teléfono también borra en la tele.
    static func escribir(_ texto: String, ime: UInt64, campo: UInt64) -> Data {
        let fin = max(texto.count - 1, 0)
        var m = Protobuf()
        m.mensaje(21) { b in
            b.entero(1, ime)
            b.entero(2, campo)
            b.mensaje(3) { e in
                e.entero(1, 1)
                e.mensaje(2) { o in
                    o.entero(1, fin)
                    o.entero(2, fin)
                    o.texto(3, texto)
                }
            }
        }
        return m.datos
    }

    static func abrir(_ enlace: String) -> Data {
        var m = Protobuf()
        m.mensaje(90) { a in a.texto(1, enlace) }
        return m.datos
    }

    /// Códigos de tecla de Android (KeyEvent).
    static func tecla(para orden: Orden) -> Int? {
        switch orden {
        case .mover(.arriba): 19
        case .mover(.abajo): 20
        case .mover(.izquierda): 21
        case .mover(.derecha): 22
        case .elegir: 23
        case .atras: 4
        case .inicio: 3
        case .playPausa: 85
        case .subirVolumen: 24
        case .bajarVolumen: 25
        case .silencio: 164
        // Google TV sólo tiene «alternar encendido»; la casa decide si hace falta.
        case .encender: 26
        default: nil
        }
    }

    static let teclaBorrar = 67

    /// El texto como lo puede teclear un control: sin acentos ni mayúsculas
    /// (la búsqueda no distingue) y sin lo que no tiene tecla.
    static func paraTeclas(_ texto: String) -> String {
        texto.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es_MX"))
            .filter { tecla(para: $0) != nil }
    }

    /// Códigos de tecla de Android para un carácter.
    static func tecla(para c: Character) -> Int? {
        if let a = c.asciiValue {
            switch a {
            case 97...122: return Int(a - 97) + 29   // a–z
            case 48...57: return Int(a - 48) + 7     // 0–9
            default: break
            }
        }
        return [" ": 62, ".": 56, ",": 55, "-": 69, "@": 77, "/": 76, "'": 75][c]
    }

    /// Las apps se abren por su enlace, como cuando alguien comparte uno.
    static let enlaces: [String: String] = [
        "YouTube": "https://www.youtube.com",
        "Netflix": "https://www.netflix.com/title",
        "Prime Video": "https://app.primevideo.com",
        "Disney+": "https://www.disneyplus.com",
        "Spotify": "spotify://",
        "Max": "https://play.max.com",
    ]

    static let nombresDePaquete: [String: String] = [
        "com.google.android.youtube.tv": "YouTube",
        "com.netflix.ninja": "Netflix",
        "com.amazon.amazonvideo.livingroom": "Prime Video",
        "com.disney.disneyplus": "Disney+",
        "com.spotify.tv.android": "Spotify",
        "com.wbd.stream": "Max",
    ]
}

extension Data {
    nonisolated init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        self.init(bytes)
    }
}
