import Foundation

// Fuera del actor principal: los controladores lo leen desde su propia tarea.
nonisolated enum TipoAparato: String, Codable, CaseIterable, Sendable {
    case appleTV, googleTV, onkyo, lg

    var nombre: String {
        switch self {
        case .appleTV: "Apple TV"
        case .googleTV: "Google TV"
        case .onkyo: "Onkyo"
        case .lg: "Tele LG"
        }
    }

    /// El tope de la escala de volumen que muestra la app: el del receptor
    /// va de 0 a 80 y el de la tele, de 0 a 100, como en sus pantallas.
    var volumenMaximo: Int { self == .lg ? 100 : 80 }

    /// Puede llevar el volumen de otro aparato (la tele por HDMI al receptor).
    var llevaVolumen: Bool { self == .onkyo || self == .lg }
}

enum Conexion: Equatable {
    case conectado
    case conectando
    /// Contesta, pero no obedece hasta emparejar con el código de la pantalla.
    case porEmparejar
    /// La tele preguntó en pantalla si deja entrar a Mando; falta que alguien
    /// acepte con su control.
    case esperandoPermiso
    /// El mensaje dice qué hacer, no sólo que falló.
    case sinConexion(String)
}

/// Un aparato de la casa: su configuración, que se guarda, y su estado en
/// vivo, que no. El estado se actualiza con lo que el aparato reporta; cuando
/// no reporta (Google TV), con lo último que mandamos.
struct Aparato: Identifiable, Equatable, Codable {
    // MARK: Configuración

    let id: UUID
    var nombre: String
    var cuarto: String
    let tipo: TipoAparato
    /// Dónde contestó la última vez. Con ella la app conecta al instante en
    /// vez de volver a buscar; si deja de contestar, se busca otra vez.
    var host: String?
    var puerto: UInt16?
    /// La cuenta del Llavero donde viven sus llaves de emparejamiento.
    var llavero: String
    /// Si el volumen de este aparato lo lleva otro (la tele por HDMI al
    /// Onkyo), las teclas de volumen le hablan a ése.
    var volumenEn: UUID?
    /// La entrada del receptor que se elige sola al tomar este aparato
    /// (el Google TV en CBL/SAT del Onkyo).
    var entradaAlElegir: String?
    var apps: [Aplicacion] = []
    var entradas: [Entrada] = []
    var modos: [Modo] = []

    // MARK: Estado en vivo

    var conexion: Conexion = .conectando
    /// Falso hasta que el aparato reporta su estado: mientras tanto la
    /// interfaz no debe afirmar «Apagado» ni «volumen 0», que serían inventos.
    var estadoConocido = false
    var encendido = false
    var volumen = 0
    var silencio = false
    /// Clave de la entrada activa en el protocolo del aparato.
    var entrada: String?
    var appAbierta: String?
    var reproduciendo: Reproduciendo?
    var reproduccionPorEmparejar = false
    /// Clave del modo de sonido activo.
    var modoSonido: String?

    /// El Apple TV sin receptor ni tele conectada sube y baja el volumen por
    /// HDMI-CEC sin saber en cuánto quedó: la interfaz no inventa un número.
    var volumenCiego: Bool { tipo == .appleTV && volumenEn == nil }

    var entradasVisibles: [Entrada] { entradas.filter(\.visible) }
    var modosVisibles: [Modo] { modos.filter(\.visible) }
    var appsVisibles: [Aplicacion] { apps.filter(\.visible) }

    init(
        id: UUID = UUID(), nombre: String, cuarto: String, tipo: TipoAparato,
        host: String? = nil, puerto: UInt16? = nil, llavero: String? = nil,
        volumenEn: UUID? = nil, entradaAlElegir: String? = nil,
        apps: [Aplicacion] = [], entradas: [Entrada] = [], modos: [Modo] = []
    ) {
        self.id = id
        self.nombre = nombre
        self.cuarto = cuarto
        self.tipo = tipo
        self.host = host
        self.puerto = puerto
        self.llavero = llavero ?? id.uuidString
        self.volumenEn = volumenEn
        self.entradaAlElegir = entradaAlElegir
        self.apps = apps
        self.entradas = entradas
        self.modos = modos
    }

    /// Sólo se guarda la configuración: el estado en vivo de ayer no sirve.
    enum CodingKeys: String, CodingKey {
        case id, nombre, cuarto, tipo, host, puerto, llavero, volumenEn, entradaAlElegir, apps, entradas, modos
    }
}

nonisolated struct Entrada: Identifiable, Equatable, Codable, Sendable {
    var id: String { clave }
    /// Cómo la conoce el protocolo: en eISCP, el código de SLI («11»).
    let clave: String
    /// Como viene impresa en el receptor (STRM BOX, BD/DVD…).
    let etiqueta: String
    /// Cómo la llama la casa (Apple TV, Tocadiscos…).
    var nombre: String
    var visible = true
}

nonisolated struct Modo: Identifiable, Equatable, Codable, Sendable {
    var id: String { clave }
    /// En eISCP, el código de LMD («01» es Direct).
    let clave: String
    var nombre: String
    var visible = true
}

/// Una app que se abre desde el control. `id` es lo que entiende el aparato:
/// el bundle en el Apple TV, el enlace en Google TV.
nonisolated struct Aplicacion: Identifiable, Equatable, Codable, Sendable, Hashable {
    let id: String
    var nombre: String
    var visible = true
}
