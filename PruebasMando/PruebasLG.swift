import Foundation
import Testing
@testable import Mando

/// De punta a punta: la casa contra una LG falsa con WebSocket seguro y SSAP.
@MainActor
@Suite(.serialized)
struct PruebasLG {
    @Test func laPrimeraVezEsperaElPermisoYLuegoConecta() async throws {
        let (casa, tele, lg) = try await armar()
        defer { tele.apagar() }

        await casa.conectar(lg)
        #expect(casa[lg]?.conexion == .esperandoPermiso)

        tele.aceptar()

        try await esperar { casa[lg]?.conexion == .conectado && casa[lg]?.volumen == 19 }
        #expect(Llavero.leer("mx.alfonsoleal.mando.lg", "PruebaLG") != nil)
    }

    @Test func conLaLlaveGuardadaYaNoPregunta() async throws {
        let tele = LGFalsa()
        defer { tele.apagar() }
        let puerto = try await tele.arrancar()
        Llavero.borrar("mx.alfonsoleal.mando.lg", "PruebaLG")
        let primera = casaCon(puerto)
        let lg1 = primera.aparatos.first { $0.tipo == .lg }!.id
        await primera.conectar(lg1)
        tele.aceptar()
        try await esperar { primera[lg1]?.conexion == .conectado }

        let segunda = casaCon(puerto)
        let lg2 = segunda.aparatos.first { $0.tipo == .lg }!.id
        await segunda.conectar(lg2)

        #expect(segunda[lg2]?.conexion == .conectado)
        #expect(tele.preguntas == 1)
    }

    @Test func elVolumenDelAppleTVMueveLaLG() async throws {
        let (casa, tele, lg) = try await armarConectada()
        defer { tele.apagar() }
        let appleTV = try #require(casa.aparatos.first { $0.tipo == .appleTV }).id

        casa.mandar(.subirVolumen, a: appleTV)
        try await esperar { tele.volumen == 20 }
        casa.mandar(.subirVolumen, a: appleTV)

        try await esperar { tele.volumen == 21 && casa[lg]?.volumen == 21 }
        #expect(casa[appleTV]?.volumenCiego == false)
    }

    @Test func reglaSilencioYApagar() async throws {
        let (casa, tele, lg) = try await armarConectada()
        defer { tele.apagar() }

        casa.mandar(.volumen(45), a: lg)
        casa.mandar(.silencio(true), a: lg)
        casa.mandar(.encender(false), a: lg)

        try await esperar { tele.volumen == 45 && tele.silencio && tele.apagada }
    }

    @Test func loQueSeHaceConSuControlSeVeEnLaApp() async throws {
        let (casa, tele, lg) = try await armarConectada()
        defer { tele.apagar() }

        tele.cambiarVolumenConSuControl(33)

        try await esperar { casa[lg]?.volumen == 33 }
    }

    @Test func siRechazanElPermisoLaAppLoDice() async throws {
        let (casa, tele, lg) = try await armar()
        defer { tele.apagar() }
        await casa.conectar(lg)
        tele.rechazar()

        // La conexión se suelta; al reintentar vuelve a preguntar.
        try await Task.sleep(for: .milliseconds(200))
        await casa.conectar(lg)
        #expect(casa[lg]?.conexion == .esperandoPermiso)
        #expect(tele.preguntas == 2)
    }

    // MARK: - Ayudantes

    private func casaCon(_ puerto: UInt16) -> Casa {
        Casa.deMuestra(
            onkyo: ControladorDemo(tipo: .onkyo),
            googleTV: ControladorDemo(tipo: .googleTV),
            appleTV: ControladorDemo(tipo: .appleTV),
            lg: ControladorLG(host: "127.0.0.1", puerto: puerto, cuenta: "PruebaLG", buscarSiFalla: false)
        )
    }

    private func armar() async throws -> (Casa, LGFalsa, Aparato.ID) {
        let tele = LGFalsa()
        let puerto = try await tele.arrancar()
        Llavero.borrar("mx.alfonsoleal.mando.lg", "PruebaLG")
        let casa = casaCon(puerto)
        let lg = try #require(casa.aparatos.first { $0.tipo == .lg }).id
        return (casa, tele, lg)
    }

    private func armarConectada() async throws -> (Casa, LGFalsa, Aparato.ID) {
        let (casa, tele, lg) = try await armar()
        await casa.conectar(lg)
        tele.aceptar()
        try await esperar { casa[lg]?.conexion == .conectado && casa[lg]?.estadoConocido == true }
        return (casa, tele, lg)
    }

    private func esperar(
        hasta limite: Duration = .seconds(5),
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
