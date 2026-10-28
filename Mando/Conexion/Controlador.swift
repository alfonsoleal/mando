import Foundation

/// Lo que cada protocolo (eISCP del Onkyo, el control de Android TV, el
/// Companion del Apple TV) tiene que saber hacer. La interfaz sólo ve esto.
nonisolated protocol Controlador: Sendable {
    func conectar() async throws
    func mandar(_ orden: Orden) async throws
    /// Lo que el aparato avisa por su cuenta. Un aparato que no avisa nada
    /// (el de demostración) regresa un flujo que nunca emite.
    var reportes: AsyncStream<Reporte> { get }
}

/// Los aparatos que saben decir qué apps tienen instaladas.
nonisolated protocol ListaApps: Controlador {
    func appsInstaladas() async throws -> [Aplicacion]
}

nonisolated enum ErrorControl: LocalizedError {
    case noSoportada(Orden, TipoAparato)
    case sinRespuesta(String)
    case onkyoNoEncontrado
    case googleTVNoEncontrado
    case appleTVNoEncontrado
    case lgNoEncontrada
    case porEmparejar
    case codigoIncorrecto
    case emparejamientoRechazado
    case emparejamientoVencido
    case pendiente(String)
    case sinCampoDeTexto
    /// No es una falla: la tele está preguntando en pantalla.
    case esperandoPermiso
    case permisoRechazado

    var errorDescription: String? {
        switch self {
        case .noSoportada(_, let tipo):
            "\(tipo.nombre) no entiende esa tecla."
        case .sinRespuesta(let nombre):
            "\(nombre) no contesta. Revisa que esté prendido y en la misma red que este teléfono."
        case .onkyoNoEncontrado:
            "No encontré el Onkyo en esta red. Revisa que tenga cable de red o Wi-Fi y que Network Standby esté activado en Setup › Hardware › Power Management."
        case .googleTVNoEncontrado:
            "No encontré el Google TV en esta red. Despiértalo con su control: en reposo apaga la Wi-Fi. Para que no lo haga, en sus ajustes busca Sistema › Energía y elige el modo estándar."
        case .appleTVNoEncontrado:
            "No encontré el Apple TV en esta red. Despiértalo con su control y revisa que esté en la misma Wi-Fi que este teléfono."
        case .lgNoEncontrada:
            "No encontré la tele LG en esta red. Préndela y revisa que esté en la misma Wi-Fi que este teléfono."
        case .porEmparejar:
            "La tele todavía no conoce este teléfono. Emparéjalo con el código que aparece en la pantalla."
        case .codigoIncorrecto:
            "Ese código no coincide con el de la tele. Revísalo o pide uno nuevo."
        case .emparejamientoRechazado:
            "La tele no aceptó el emparejamiento. Vuelve a pedir el código."
        case .emparejamientoVencido:
            "El código ya venció. Pide uno nuevo."
        case .pendiente(let texto):
            texto
        case .esperandoPermiso:
            "La tele pregunta si dejas entrar a Mando. Acepta con su control."
        case .permisoRechazado:
            "La tele no dio permiso. Toca Reintentar y acepta en la pantalla con su control."
        case .sinCampoDeTexto:
            "No hay dónde escribir: abre la búsqueda en la tele y vuelve a intentarlo."
        }
    }
}

/// Simula los aparatos para trabajar la interfaz sin tenerlos enfrente. Tarda
/// lo que tarda uno real en la red de la casa, para que la interfaz se diseñe
/// con esa espera y no con una respuesta instantánea que nunca va a tener.
nonisolated struct ControladorDemo: Controlador {
    let tipo: TipoAparato
    var reportes: AsyncStream<Reporte> { AsyncStream { _ in } }

    func conectar() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }

    func mandar(_ orden: Orden) async throws {
        switch (tipo, orden) {
        case (.onkyo, .mover), (.onkyo, .elegir), (.onkyo, .abrirApp), (.onkyo, .escribir):
            throw ErrorControl.noSoportada(orden, tipo)
        default:
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}

#if DEBUG
/// Para revisar la interfaz en el simulador con datos creíbles: conecta y
/// reporta un estado como lo haría el aparato real. Se usa con `-casaDeMuestra`.
nonisolated struct ControladorMuestra: Controlador {
    let tipo: TipoAparato
    let reportes: AsyncStream<Reporte>
    private let avisar: AsyncStream<Reporte>.Continuation

    init(tipo: TipoAparato) {
        self.tipo = tipo
        (reportes, avisar) = AsyncStream.makeStream()
    }

    func conectar() async throws {
        try await Task.sleep(for: .milliseconds(300))
        avisar.yield(.encendido(true))
        switch tipo {
        case .onkyo:
            avisar.yield(.volumen(32)); avisar.yield(.entrada("01")); avisar.yield(.modoSonido("01"))
        case .lg:
            avisar.yield(.volumen(19))
        case .appleTV:
            avisar.yield(.app("Infuse"))
            avisar.yield(.reproduciendo(Reproduciendo(
                titulo: "La isla de los perros", detalle: "Severance · T2 E5",
                duracion: 52 * 60, transcurrido: 18 * 60 + 40, velocidad: 1
            )))
        case .googleTV:
            avisar.yield(.app("YouTube"))
        }
    }

    func mandar(_ orden: Orden) async throws {}
}
#endif
