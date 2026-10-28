import SwiftUI

@main
struct MandoApp: App {
    // Dentro de las pruebas la app sólo es anfitriona: no debe leer la casa
    // guardada ni salir a la red mientras las pruebas usan aparatos falsos.
    @State private var casa = MandoApp.casaInicial()
    @Environment(\.scenePhase) private var fase

    private static func casaInicial() -> Casa {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return Casa(aparatos: []) }
        #if DEBUG
        if CommandLine.arguments.contains("-casaDeMuestra") {
            return Casa(aparatos: Catalogo.casaAnterior()) { ControladorMuestra(tipo: $0.tipo) }
        }
        #endif
        return Casa.alAbrir()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if CommandLine.arguments.contains("-maquetaDeck") {
                    MaquetaPantallaDeck()
                } else {
                    Raiz()
                }
                #else
                Raiz()
                #endif
            }
            .environment(casa)
            .tint(.hueso)
        }
        // iOS corta las conexiones de una app suspendida: al volver se revisan
        // para que la primera tecla no falle.
        .onChange(of: fase) { _, nueva in
            if nueva == .active { casa.reconectar() }
        }
    }
}
