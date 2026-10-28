import Foundation
import Testing
@testable import Mando

/// Lo que se está viendo en el Apple TV, de punta a punta: Companion falso
/// para el control y AirPlay falso para lo que suena, con las tres
/// conexiones cifradas de AirPlay.
@MainActor
@Suite(.serialized)
struct PruebasReproduccion {
    @Test func conLasLlavesDeCompanionLlegaLoQueSuena() async throws {
        let companion = AppleTVFalso()
        defer { companion.apagar() }
        let puerto = try await companion.arrancar()
        Credenciales.borrar("PruebaRepro")
        Credenciales.borrar("PruebaRepro-AirPlay")
        // Primero se empareja Companion, luego la tele AirPlay comparte su identidad.
        let control = ControladorAppleTV(host: "127.0.0.1", puerto: puerto, cuenta: "PruebaRepro", buscarSiFalla: false, puertoAirPlay: 1)
        let previa = casa(control)
        let apple = previa.aparatos.first { $0.tipo == .appleTV }!.id
        _ = await previa.pedirCodigo(apple)
        _ = await previa.emparejar(apple, codigo: companion.pin)

        let airplay = AirPlayFalso(identidadDe: companion)
        defer { airplay.apagar() }
        let puertoAirPlay = try await airplay.arrancar()
        let casa = casa(ControladorAppleTV(host: "127.0.0.1", puerto: puerto, cuenta: "PruebaRepro", buscarSiFalla: false, puertoAirPlay: puertoAirPlay))
        let id = casa.aparatos.first { $0.tipo == .appleTV }!.id

        await casa.conectar(id)

        try await esperar { casa[id]?.reproduciendo?.portada != nil }
        let r = try #require(casa[id]?.reproduciendo)
        #expect(r.titulo == "La isla de los perros")
        #expect(r.detalle == "Severance · T2 E5")
        #expect(r.duracion == 3120)
        #expect(r.velocidad == 1)
        #expect(abs((r.transcurridoAhora() ?? 0) - (18 * 60 + 40)) < 5)
        #expect(r.portada == airplay.portada)
        #expect(casa[id]?.appAbierta == "Infuse")
        // El saludo de MRP en orden, y cada «sync» de la tele contestado.
        #expect(Array(airplay.tiposMRP.prefix(3)) == [15, 38, 16])
        #expect(airplay.respuestasRply >= 2)
        #expect(airplay.avisosContestados == 1)
    }

    @Test func siLaTeleNoReconoceLasLlavesPideElPinDeAirPlay() async throws {
        let companion = AppleTVFalso()
        defer { companion.apagar() }
        let puerto = try await companion.arrancar()
        // Un AirPlay con otra identidad: las llaves de Companion no le sirven.
        let airplay = AirPlayFalso()
        defer { airplay.apagar() }
        let puertoAirPlay = try await airplay.arrancar()
        Credenciales.borrar("PruebaRepro")
        Credenciales.borrar("PruebaRepro-AirPlay")
        let casa = casa(ControladorAppleTV(host: "127.0.0.1", puerto: puerto, cuenta: "PruebaRepro", buscarSiFalla: false, puertoAirPlay: puertoAirPlay))
        let id = casa.aparatos.first { $0.tipo == .appleTV }!.id
        _ = await casa.pedirCodigo(id)
        _ = await casa.emparejar(id, codigo: companion.pin)

        try await esperar { casa[id]?.reproduccionPorEmparejar == true }
        #expect(await casa.pedirCodigoReproduccion(id) == nil)
        #expect(await casa.emparejarReproduccion(id, codigo: airplay.pin) == nil)

        try await esperar { casa[id]?.reproduciendo?.titulo == "La isla de los perros" }
        #expect(casa[id]?.reproduccionPorEmparejar == false)
    }

    @Test func mantieneViveLaSesionConElLatido() async throws {
        let companion = AppleTVFalso()
        defer { companion.apagar() }
        let puerto = try await companion.arrancar()
        Credenciales.borrar("PruebaRepro")
        Credenciales.borrar("PruebaRepro-AirPlay")
        let previa = casa(ControladorAppleTV(host: "127.0.0.1", puerto: puerto, cuenta: "PruebaRepro", buscarSiFalla: false, puertoAirPlay: 1))
        let a = previa.aparatos.first { $0.tipo == .appleTV }!.id
        _ = await previa.pedirCodigo(a)
        _ = await previa.emparejar(a, codigo: companion.pin)
        let airplay = AirPlayFalso(identidadDe: companion)
        defer { airplay.apagar() }
        let puertoAirPlay = try await airplay.arrancar()
        let casa = casa(ControladorAppleTV(host: "127.0.0.1", puerto: puerto, cuenta: "PruebaRepro", buscarSiFalla: false, puertoAirPlay: puertoAirPlay))
        await casa.conectar(casa.aparatos.first { $0.tipo == .appleTV }!.id)

        // El primer latido sale 2 segundos después de abrir.
        try await esperar(hasta: .seconds(10)) { airplay.latidos >= 1 }
    }

    @Test func enPausaLaBarraNoAvanzaYLasActualizacionesSeJuntan() {
        var e = EstadoMRP()
        _ = e.recibir(MRP.mensaje(MRP.setState) { s in
            s.mensaje(3) { cola in
                cola.entero(1, 0)
                cola.mensaje(2) { item in
                    item.texto(1, "c1")
                    item.mensaje(2) { md in
                        md.texto(1, "Canción")
                        md.texto(7, "Artista")
                        md.doble(14, 200)
                        md.doble(35, 50)
                        md.doble(74, Date.now.timeIntervalSinceReferenceDate - 30)
                    }
                }
            }
            s.entero(6, 2) // pausa
            s.mensaje(9) { r in r.mensaje(2) { c in c.texto(2, "com.apple.TVMusic") } }
        })
        let pausa = e.reproduciendo
        #expect(pausa?.velocidad == 0)
        #expect(pausa?.transcurridoAhora() == 50)
        #expect(pausa?.detalle == "Artista")

        // UPDATE_CONTENT_ITEM cambia sólo lo que trae.
        _ = e.recibir(MRP.mensaje(MRP.updateContentItem) { u in
            u.mensaje(1) { item in
                item.texto(1, "c1")
                item.mensaje(2) { md in md.texto(1, "Otra canción") }
            }
        })
        #expect(e.reproduciendo?.titulo == "Otra canción")
        #expect(e.reproduciendo?.duracion == 200)
    }

    /// La secuencia que mandó un Apple TV real con Disney+ al frente:
    /// avisos de reproductor de otras apps y una respuesta de portada sin
    /// metadatos. El título no se debe perder.
    @Test func secuenciaRealConDisney() {
        var e = EstadoMRP()
        func ruta(_ app: String, _ jugador: String) -> (inout Protobuf) -> Void {
            { r in
                r.mensaje(2) { c in c.texto(2, app) }
                r.mensaje(3) { p in p.texto(1, jugador) }
            }
        }
        _ = e.recibir(MRP.mensaje(MRP.setNowPlayingClient) { s in s.mensaje(1) { c in c.texto(2, "com.disney.disneyplus") } })
        _ = e.recibir(MRP.mensaje(MRP.setState) { s in
            s.mensaje(3) { cola in
                cola.entero(1, 0)
                cola.mensaje(2) { item in
                    item.texto(1, "peli")
                    item.mensaje(2) { md in
                        md.texto(1, "10 cosas que odio de ti")
                        md.doble(14, 5800)
                        md.booleano(19, true)
                        md.doble(35, 600)
                        md.doble(74, Date.now.timeIntervalSinceReferenceDate)
                    }
                }
            }
            s.entero(6, 1)
            s.mensaje(9, ruta("com.disney.disneyplus", "6EAB"))
        })
        _ = e.recibir(MRP.mensaje(MRP.setNowPlayingPlayer) { s in s.mensaje(1, ruta("com.apple.TVMusic", "Music")) })
        _ = e.recibir(MRP.mensaje(MRP.setState) { s in
            s.entero(6, 2)
            s.mensaje(9, ruta("com.apple.TVMusic", "Music"))
        })
        // La portada llega en un elemento sin metadatos.
        _ = e.recibir(MRP.mensaje(MRP.setState) { s in
            s.mensaje(3) { cola in
                cola.entero(1, 0)
                cola.mensaje(2) { item in
                    item.texto(1, "peli")
                    item.mensaje(2) { _ in }
                    item.bytes(3, Data([9, 9, 9]))
                }
            }
            s.mensaje(9, ruta("com.disney.disneyplus", "6EAB"))
        })

        #expect(e.app == "com.disney.disneyplus")
        #expect(e.reproduciendo?.titulo == "10 cosas que odio de ti")
        #expect(e.reproduciendo?.portada == Data([9, 9, 9]))
        #expect(e.reproduciendo?.velocidad == 1)
    }

    @Test func tramaDelCanalDeDatos() {
        let t = SesionAirPlay.trama(tipo: "sync", comando: "comm", secuencia: 0x1_2345_6789, cuerpo: Data([1, 2]))
        #expect(t.count == 34)
        #expect(Array(t.prefix(4)) == [0, 0, 0, 34])
        #expect(t[4..<8] == Data("sync".utf8))
        #expect(t[16..<20] == Data("comm".utf8))
        #expect(Array(t[20..<28]) == [0, 0, 0, 1, 0x23, 0x45, 0x67, 0x89])
    }

    @Test func cifradoPorBloquesIdaYVuelta() throws {
        let secreto = Data((0..<32).map { UInt8($0) })
        var telefono = CanalHAP(secreto: secreto, sal: "S", infoEnviar: "A", infoRecibir: "B")
        var tele = CanalHAP(secreto: secreto, sal: "S", infoEnviar: "B", infoRecibir: "A")
        let largo = Data((0..<2500).map { UInt8($0 % 251) })
        var bufer = try telefono.cifrar(largo) + telefono.cifrar(Data("hola".utf8))
        // Llega partido: primero la mitad.
        var mitad = bufer.prefix(1500)
        let primero = try tele.descifrar(&mitad)
        bufer = mitad + bufer.dropFirst(1500)
        let resto = try tele.descifrar(&bufer)
        #expect(primero + resto == largo + Data("hola".utf8))
    }

    // MARK: - Ayudantes

    private func casa(_ apple: ControladorAppleTV) -> Casa {
        Casa.deMuestra(onkyo: ControladorDemo(tipo: .onkyo), googleTV: ControladorDemo(tipo: .googleTV), appleTV: apple, lg: ControladorDemo(tipo: .lg))
    }

    private func esperar(
        hasta limite: Duration = .seconds(15),
        _ condicion: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let fin = ContinuousClock.now + limite
        while ContinuousClock.now < fin {
            if condicion() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("No se cumplió a tiempo", sourceLocation: sourceLocation)
    }
}
