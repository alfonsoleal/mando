import Foundation
import Testing
@testable import Mando

/// De punta a punta: la casa de la app contra un receptor falso en localhost.
@MainActor
@Suite(.serialized)
struct PruebasOnkyo {
    @Test func alConectarMuestraElEstadoRealDelReceptor() async throws {
        let (casa, receptor, onkyo) = try await armar()
        defer { receptor.apagar() }

        await casa.conectar(onkyo)
        try await esperar { casa[onkyo]?.volumen == 30 }
        let a = try #require(casa[onkyo])
        #expect(a.conexion == .conectado)
        #expect(a.encendido)
        #expect(a.entrada == "11")
        #expect(a.modoSonido == "01")
    }

    @Test func elVolumenDelGoogleTVLlegaAlReceptor() async throws {
        let (casa, receptor, onkyo) = try await armar()
        defer { receptor.apagar() }
        let googleTV = try #require(casa.aparatos.first { $0.tipo == .googleTV }).id
        await casa.conectar(onkyo)
        try await esperar { casa[onkyo]?.volumen == 30 }

        casa.mandar(.subirVolumen, a: googleTV)
        casa.mandar(.subirVolumen, a: googleTV)

        try await esperar { receptor.valor("MVL") == "20" }
        try await esperar { casa[onkyo]?.volumen == 32 }
    }

    @Test func cambiarEntradaYModo() async throws {
        let (casa, receptor, onkyo) = try await armar()
        defer { receptor.apagar() }
        await casa.conectar(onkyo)

        casa.mandar(.entrada("22"), a: onkyo)
        casa.mandar(.modoSonido("11"), a: onkyo)
        casa.mandar(.volumen(45), a: onkyo)

        try await esperar { receptor.valor("SLI") == "22" && receptor.valor("LMD") == "11" }
        #expect(receptor.valor("MVL") == "2D")
        #expect(receptor.recibidos.contains("MVL2D"))
    }

    @Test func loQueSeHaceConElControlDeFabricaSeVeEnLaApp() async throws {
        let (casa, receptor, onkyo) = try await armar()
        defer { receptor.apagar() }
        await casa.conectar(onkyo)
        try await esperar { casa[onkyo]?.volumen == 30 }

        receptor.cambiarDesdeElControl("MVL", "28")
        receptor.cambiarDesdeElControl("AMT", "01")
        receptor.cambiarDesdeElControl("PWR", "00")

        try await esperar { casa[onkyo]?.volumen == 40 && casa[onkyo]?.silencio == true && casa[onkyo]?.encendido == false }
    }

    @Test func armaMensajesQueLleganPartidos() async throws {
        let (casa, receptor, onkyo) = try await armar()
        defer { receptor.apagar() }
        receptor.partirRespuestas = true
        await casa.conectar(onkyo)
        try await esperar { casa[onkyo]?.volumen == 30 && casa[onkyo]?.entrada == "11" }
    }

    @Test func seReconectaSoloSiElReceptorCortaLaConexion() async throws {
        let (casa, receptor, onkyo) = try await armar()
        defer { receptor.apagar() }
        await casa.conectar(onkyo)
        try await esperar { casa[onkyo]?.volumen == 30 }

        receptor.cortarConexiones()
        try await Task.sleep(for: .milliseconds(200))
        casa.mandar(.encender(false), a: onkyo)

        try await esperar { receptor.valor("PWR") == "00" }
    }

    @Test func sinReceptorElMensajeDiceQueHacer() async throws {
        // Un puerto donde nadie escucha.
        let receptor = try ReceptorFalso()
        let puerto = try await receptor.arrancar()
        receptor.apagar()
        let casa = Casa.deMuestra(onkyo: ControladorOnkyo(host: "127.0.0.1", puerto: puerto, buscarSiFalla: false), googleTV: ControladorDemo(tipo: .googleTV), appleTV: ControladorDemo(tipo: .appleTV), lg: ControladorDemo(tipo: .lg))
        let onkyo = try #require(casa.aparatos.first { $0.tipo == .onkyo }).id

        await casa.conectar(onkyo)

        guard case .sinConexion(let mensaje) = casa[onkyo]?.conexion else {
            Issue.record("Debió quedar sin conexión")
            return
        }
        #expect(mensaje.contains("Revisa"))
    }

    @Test func unaDireccionQueNoContestaRespetaElLimite() async throws {
        // 192.0.2.0/24 está reservada para documentación: nadie contesta ahí,
        // como una IP de la casa donde no hay aparato.
        let inicio = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            _ = try await TCP.conectar(a: "192.0.2.1", puerto: EISCP.puerto, limite: .milliseconds(300))
        }
        #expect(ContinuousClock.now - inicio < .seconds(2))
    }

    @Test func traduceOrdenesAComandos() {
        #expect(EISCP.comandos(para: .volumen(32)) == ["MVL20"])
        #expect(EISCP.comandos(para: .volumen(200)) == ["MVL50"])
        #expect(EISCP.comandos(para: .encender(true)) == ["PWR01"])
        #expect(EISCP.comandos(para: .mover(.arriba)).isEmpty)
        #expect(EISCP.reporte(de: "MVLN/A") == nil)
    }

    // MARK: - Ayudantes

    private func armar() async throws -> (Casa, ReceptorFalso, Aparato.ID) {
        let receptor = try ReceptorFalso()
        let puerto = try await receptor.arrancar()
        let casa = Casa.deMuestra(onkyo: ControladorOnkyo(host: "127.0.0.1", puerto: puerto, buscarSiFalla: false), googleTV: ControladorDemo(tipo: .googleTV), appleTV: ControladorDemo(tipo: .appleTV), lg: ControladorDemo(tipo: .lg))
        let onkyo = try #require(casa.aparatos.first { $0.tipo == .onkyo }).id
        return (casa, receptor, onkyo)
    }

    /// Las órdenes viajan por la red de verdad: se espera a que se cumpla la
    /// condición en vez de dormir un tiempo fijo.
    private func esperar(
        hasta limite: Duration = .seconds(3),
        _ condicion: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let fin = ContinuousClock.now + limite
        while ContinuousClock.now < fin {
            if condicion() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("No se cumplió a tiempo", sourceLocation: sourceLocation)
    }
}
