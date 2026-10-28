import Foundation

/// El Media Remote Protocol: lo que usan la pantalla de bloqueo y el Centro de
/// Control del iPhone para saber qué suena en un Apple TV. Viaja como
/// protobuf dentro del canal de datos de AirPlay. Los números de campo salen
/// de los .proto de pyatv.
nonisolated enum MRP {
    // Tipos de ProtocolMessage y el campo de extensión de cada uno.
    static let setState = (tipo: 4, campo: 9)
    static let deviceInfo = (tipo: 15, campo: 20)
    static let clientUpdatesConfig = (tipo: 16, campo: 21)
    static let playbackQueueRequest = (tipo: 32, campo: 37)
    static let setConnectionState = (tipo: 38, campo: 42)
    static let setNowPlayingClient = (tipo: 46, campo: 50)
    static let setNowPlayingPlayer = (tipo: 47, campo: 51)
    static let updateContentItem = (tipo: 56, campo: 60)

    /// Un ProtocolMessage con su extensión.
    static func mensaje(_ t: (tipo: Int, campo: Int), identificador: String? = nil, _ armar: (inout Protobuf) -> Void) -> Data {
        var m = Protobuf()
        m.entero(1, t.tipo)
        if let identificador { m.texto(2, identificador) }
        m.entero(4, 0)
        m.mensaje(t.campo, armar)
        m.texto(85, UUID().uuidString)
        return m.datos
    }

    /// Lo que se manda al abrir el canal, en orden: quiénes somos, que ya
    /// estamos conectados y qué avisos queremos.
    static func saludo(nombre: String) -> [Data] {
        [
            mensaje(deviceInfo, identificador: UUID().uuidString) { d in
                d.texto(1, UUID().uuidString)
                d.texto(2, nombre)
                d.texto(3, "iPhone")
                d.texto(4, "18G82")
                d.texto(5, "com.apple.TVRemote")
                d.texto(6, "344.28")
                d.entero(7, 1)
                d.entero(8, 108)
                d.booleano(9, true)
                d.booleano(10, true)
                d.texto(12, "com.apple.TVMusic")
                d.booleano(13, true)
                d.booleano(14, true)
                d.booleano(15, true)
                d.entero(17, 2)
                d.entero(21, 1)
                d.entero(22, 1)
            },
            mensaje(setConnectionState) { $0.entero(1, 2) },
            mensaje(clientUpdatesConfig, identificador: UUID().uuidString) { c in
                c.booleano(1, true)
                c.booleano(2, false)
                c.booleano(3, true)
                c.booleano(4, true)
                c.booleano(5, true)
            },
        ]
    }

    /// Pide la portada del elemento en `posicion` de la cola.
    static func pedirPortada(posicion: Int, ancho: Double = 300) -> Data {
        mensaje(playbackQueueRequest, identificador: UUID().uuidString) { p in
            p.entero(1, posicion)
            p.entero(2, 1)
            p.doble(4, ancho)
            p.doble(5, -1)
            p.booleano(13, true)
        }
    }

    /// Separa los mensajes de un paquete del canal de datos: van con su largo
    /// en varint, salvo cuando el primer byte ya es el campo 1 (0x08), que
    /// es un solo mensaje sin largo.
    static func separar(_ datos: Data) -> [Data] {
        guard let primero = datos.first else { return [] }
        if primero == 0x08 { return [datos] }
        var bufer = datos
        return Marco.extraer(de: &bufer)
    }
}

/// Lo que se va sabiendo de cada reproductor del Apple TV, para decir qué
/// suena en el que está al frente. Como pyatv: por app y por reproductor.
nonisolated struct EstadoMRP {
    private struct Elemento {
        let id: String
        var metadatos: [Int: Protobuf.Valor] = [:]
    }

    private struct Reproductor {
        var estado: Int = 0
        var elementos: [Elemento] = []
        var posicion = 0
    }

    private var reproductores: [String: Reproductor] = [:]
    private var portadas: [String: Data] = [:]
    private var portadasPedidas: Set<String> = []
    private var appAlFrente: String?
    private var reproductorAlFrente: [String: String] = [:]
    private var ultimo: String?

    /// El bundle de la app que está reproduciendo, si lo dijo.
    var app: String? { appAlFrente }

    /// Procesa un ProtocolMessage. Regresa la portada que hay que pedir, si
    /// apareció un elemento que la tiene y todavía no se pidió.
    mutating func recibir(_ datos: Data) -> Data? {
        let m = Protobuf.campos(datos)
        switch Int(m[1]?.entero ?? 0) {
        case MRP.setNowPlayingClient.tipo:
            if let c = m[MRP.setNowPlayingClient.campo]?.bytes, let cliente = Protobuf.campos(c)[1]?.bytes {
                appAlFrente = Protobuf.campos(cliente)[2]?.texto
            }
        case MRP.setNowPlayingPlayer.tipo:
            if let p = m[MRP.setNowPlayingPlayer.campo]?.bytes, let ruta = Protobuf.campos(p)[1]?.bytes {
                // Dice qué reproductor usa esa app, no que la app pasó al
                // frente: el Apple TV lo manda por cada app (Música, Búsqueda…)
                // y tomarlo como «al frente» perdía lo que de verdad suena.
                let (app, jugador) = Self.ruta(ruta)
                if let app { reproductorAlFrente[app] = jugador }
            }
        case MRP.setState.tipo:
            guard let s = m[MRP.setState.campo]?.bytes else { break }
            let estado = Protobuf.campos(s)
            let cola = estado[3]?.bytes.map(Protobuf.campos)
            let elementos = cola?.todos(2).compactMap(\.bytes).map(Self.elemento) ?? []
            // La respuesta a un pedido de portada trae los bytes de la imagen.
            for (id, portada) in elementos.compactMap({ e in e.portada.map { (e.id, $0) } }) {
                portadas[id] = portada
            }
            guard let ruta = estado[9]?.bytes else { break }
            let (app, jugador) = Self.ruta(ruta)
            let llave = "\(app ?? "")/\(jugador)"
            var r = reproductores[llave] ?? Reproductor()
            if let e = estado[6]?.entero { r.estado = Int(e) }
            if !elementos.isEmpty {
                // Se juntan con lo que ya se sabía de cada elemento: la
                // respuesta con la portada trae el elemento sin metadatos, y
                // reemplazarlo borraba el título.
                let antes = Dictionary(r.elementos.map { ($0.id, $0.metadatos) }, uniquingKeysWith: { a, _ in a })
                r.elementos = elementos.map { e in
                    Elemento(id: e.id, metadatos: (antes[e.id] ?? [:]).merging(e.metadatos) { $1 })
                }
                r.posicion = Int(cola?[1]?.entero ?? 0)
            }
            reproductores[llave] = r
            ultimo = llave
            if appAlFrente == nil { appAlFrente = app }
        case MRP.updateContentItem.tipo:
            guard let u = m[MRP.updateContentItem.campo]?.bytes else { break }
            let campos = Protobuf.campos(u)
            for nuevo in campos.todos(1).compactMap(\.bytes).map(Self.elemento) {
                for llave in reproductores.keys {
                    guard let i = reproductores[llave]?.elementos.firstIndex(where: { $0.id == nuevo.id }) else { continue }
                    reproductores[llave]?.elementos[i].metadatos.merge(nuevo.metadatos) { $1 }
                }
                if let p = nuevo.portada { portadas[nuevo.id] = p }
            }
        default:
            break
        }
        return portadaPendiente()
    }

    /// Lo que suena en el reproductor al frente, listo para la pantalla.
    var reproduciendo: Reproduciendo? {
        guard let r = actual, r.posicion < r.elementos.count else { return nil }
        let e = r.elementos[r.posicion]
        let md = e.metadatos
        guard let titulo = md[1]?.texto, !titulo.isEmpty else { return nil }

        var detalle: String?
        if let serie = md[63]?.texto, !serie.isEmpty {
            detalle = serie
            if let t = md[10]?.entero, let ep = md[11]?.entero, t > 0 { detalle! += " · T\(t) E\(ep)" }
        } else {
            detalle = [md[7]?.texto, md[6]?.texto].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if detalle?.isEmpty == true { detalle = nil }
        }
        let duracion = md[14]?.doble.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        // Sin la marca de tiempo de la tele no se puede saber dónde va.
        let marca = md[74]?.doble
        let reproduciendo = r.estado == 1
        let velocidad = reproduciendo ? Double(md[39]?.flotante ?? 1) : 0
        return Reproduciendo(
            titulo: titulo,
            detalle: detalle,
            duracion: duracion,
            transcurrido: marca != nil ? md[35]?.doble : nil,
            medido: marca.map { Date(timeIntervalSinceReferenceDate: $0) } ?? .now,
            velocidad: velocidad,
            portada: portadas[e.id]
        )
    }

    private var actual: Reproductor? {
        if let app = appAlFrente {
            if let jugador = reproductorAlFrente[app], let r = reproductores["\(app)/\(jugador)"] { return r }
            if let ultimo, ultimo.hasPrefix(app + "/") { return reproductores[ultimo] }
            if let r = reproductores.first(where: { $0.key.hasPrefix(app + "/") })?.value { return r }
        }
        return ultimo.flatMap { reproductores[$0] }
    }

    private mutating func portadaPendiente() -> Data? {
        guard let r = actual, r.posicion < r.elementos.count else { return nil }
        let e = r.elementos[r.posicion]
        guard e.metadatos[19]?.entero == 1, portadas[e.id] == nil, !portadasPedidas.contains(e.id) else { return nil }
        portadasPedidas.insert(e.id)
        return MRP.pedirPortada(posicion: r.posicion)
    }

    private static func ruta(_ datos: Data) -> (app: String?, jugador: String) {
        let ruta = Protobuf.campos(datos)
        let app = ruta[2]?.bytes.flatMap { Protobuf.campos($0)[2]?.texto }
        let jugador = ruta[3]?.bytes.flatMap { Protobuf.campos($0)[1]?.texto } ?? ""
        return (app, jugador)
    }

    private static func elemento(_ datos: Data) -> (id: String, metadatos: [Int: Protobuf.Valor], portada: Data?) {
        let c = Protobuf.campos(datos)
        var metadatos: [Int: Protobuf.Valor] = [:]
        if let md = c[2]?.bytes {
            for (campo, valor) in Protobuf.campos(md).lista { metadatos[campo] = valor }
        }
        let portada = c[3]?.bytes.flatMap { $0.isEmpty ? nil : $0 }
        return (c[1]?.texto ?? "", metadatos, portada)
    }
}
