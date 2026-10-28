import Foundation
import Observation

/// Los aparatos de la casa, a cuál se le está hablando y sus controladores.
/// La configuración se guarda en el teléfono en cada cambio.
@Observable
final class Casa {
    private(set) var aparatos: [Aparato]
    private(set) var seleccionado: Aparato.ID?
    /// El último error, para mostrarlo un momento sobre el control.
    private(set) var aviso: String?

    private let almacen: Almacen?
    private let fabrica: @MainActor (Aparato) -> any Controlador
    private var controladores: [Aparato.ID: any Controlador] = [:]
    private var tareaAviso: Task<Void, Never>?
    private var escuchas: [Aparato.ID: Task<Void, Never>] = [:]

    init(
        aparatos: [Aparato],
        seleccionado: Aparato.ID? = nil,
        almacen: Almacen? = nil,
        fabrica: @escaping @MainActor (Aparato) -> any Controlador = Controladores.para
    ) {
        self.aparatos = aparatos
        self.almacen = almacen
        self.fabrica = fabrica
        self.seleccionado = aparatos.contains { $0.id == seleccionado } ? seleccionado : aparatos.first?.id
        for a in aparatos { controladores[a.id] = fabrica(a) }
    }

    /// La casa guardada en el teléfono. Sin nada guardado, si hay llaves de la
    /// versión anterior (cuando la casa estaba escrita en el
    /// código), se arma esa casa para no perder los emparejamientos; si no,
    /// la casa empieza vacía y la app ofrece buscar aparatos.
    static func alAbrir(_ almacen: Almacen = .predeterminado) -> Casa {
        if let guardada = almacen.cargar() {
            return Casa(aparatos: guardada.aparatos, seleccionado: guardada.ultimo, almacen: almacen)
        }
        let habiaEmparejamientos = Credenciales.leer("AppleTV") != nil
            || Llavero.leer(ControladorLG.servicio, "LG") != nil
        let casa = Casa(aparatos: habiaEmparejamientos ? Catalogo.casaAnterior() : [], almacen: almacen)
        casa.guardar()
        return casa
    }

    subscript(id: Aparato.ID) -> Aparato? {
        aparatos.first { $0.id == id }
    }

    var actual: Aparato? { seleccionado.flatMap { self[$0] } ?? aparatos.first }

    /// Los cuartos en el orden en que aparecen sus aparatos.
    var cuartos: [String] {
        var vistos: [String] = []
        for a in aparatos where !vistos.contains(a.cuarto) { vistos.append(a.cuarto) }
        return vistos
    }

    /// Quién puede llevar el volumen de `id`: los receptores y las teles de la casa.
    func quienesLlevanVolumen(de id: Aparato.ID) -> [Aparato] {
        aparatos.filter { $0.tipo.llevaVolumen && $0.id != id }
    }

    // MARK: - Elegir

    /// Al tomar un aparato con entrada asignada en el receptor (el Google TV
    /// en CBL/SAT), el receptor se cambia solo a esa entrada.
    func seleccionar(_ id: Aparato.ID) {
        seleccionado = id
        guardar()
        guard let a = self[id], let clave = a.entradaAlElegir, let receptor = a.volumenEn,
              self[receptor]?.entrada != clave else { return }
        mandar(.entrada(clave), a: receptor)
    }

    // MARK: - Configurar

    func agregar(_ nuevo: Aparato) {
        aparatos.append(nuevo)
        controladores[nuevo.id] = fabrica(nuevo)
        seleccionado = nuevo.id
        guardar()
        Task { await conectar(nuevo.id) }
    }

    /// Guarda la configuración editada sin perder el estado en vivo. Si cambió
    /// a dónde conectar, se arma un controlador nuevo y se reconecta.
    func actualizar(_ editado: Aparato) {
        guard let i = aparatos.firstIndex(where: { $0.id == editado.id }) else { return }
        let antes = aparatos[i]
        var a = antes
        a.nombre = editado.nombre
        a.cuarto = editado.cuarto
        a.host = editado.host
        a.puerto = editado.puerto
        a.volumenEn = editado.volumenEn
        a.entradaAlElegir = editado.entradaAlElegir
        a.apps = editado.apps
        a.entradas = editado.entradas
        a.modos = editado.modos
        aparatos[i] = a
        guardar()
        if antes.host != a.host || antes.puerto != a.puerto {
            rehacerControlador(a.id)
        }
    }

    func mover(desde origen: IndexSet, hasta destino: Int) {
        aparatos.move(fromOffsets: origen, toOffset: destino)
        guardar()
    }

    func quitar(_ id: Aparato.ID) {
        guard let a = self[id] else { return }
        Controladores.olvidar(a)
        escuchas.removeValue(forKey: id)?.cancel()
        controladores.removeValue(forKey: id)
        aparatos.removeAll { $0.id == id }
        // Nadie puede seguir mandando su volumen a un aparato que ya no está.
        for i in aparatos.indices where aparatos[i].volumenEn == id {
            aparatos[i].volumenEn = nil
            aparatos[i].entradaAlElegir = nil
        }
        if seleccionado == id { seleccionado = aparatos.first?.id }
        guardar()
    }

    /// Borra las llaves de emparejamiento: la próxima conexión vuelve a pedir
    /// el código o el permiso en la tele.
    func olvidarEmparejamiento(_ id: Aparato.ID) {
        guard let a = self[id] else { return }
        Controladores.olvidar(a)
        rehacerControlador(id)
    }

    /// El segundo emparejamiento del Apple TV, el de AirPlay, para ver lo
    /// que se reproduce. Regresan el error para la hoja, o nil.
    func pedirCodigoReproduccion(_ id: Aparato.ID) async -> String? {
        guard let control = controladores[id] as? ControladorAppleTV else { return nil }
        do { try await control.pedirCodigoReproduccion(); return nil } catch { return error.localizedDescription }
    }

    func emparejarReproduccion(_ id: Aparato.ID, codigo: String) async -> String? {
        guard let control = controladores[id] as? ControladorAppleTV else { return nil }
        do {
            try await control.confirmarReproduccion(codigo: codigo)
            cambiar(id) { $0.reproduccionPorEmparejar = false }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// La lista real de apps del aparato, si sabe darla (el Apple TV sí).
    func appsInstaladas(_ id: Aparato.ID) async throws -> [Aplicacion]? {
        guard let control = controladores[id] as? any ListaApps else { return nil }
        return try await control.appsInstaladas()
    }

    private func rehacerControlador(_ id: Aparato.ID) {
        guard let a = self[id] else { return }
        escuchas.removeValue(forKey: id)?.cancel()
        controladores[id] = fabrica(a)
        cambiar(id) { $0.estadoConocido = false; $0.conexion = .conectando }
        Task { await conectar(id) }
    }

    func guardar() {
        almacen?.guardar(.init(aparatos: aparatos, ultimo: seleccionado))
    }

    // MARK: - Conectar

    func conectarTodos() async {
        await withTaskGroup { grupo in
            for aparato in aparatos {
                grupo.addTask { await self.conectar(aparato.id) }
            }
        }
    }

    /// Al volver a la app. iOS corta las conexiones de una app suspendida;
    /// cada controlador revisa la suya y sólo reconecta si hace falta.
    func reconectar() {
        for a in aparatos where a.conexion != .porEmparejar && a.conexion != .esperandoPermiso {
            Task { await conectar(a.id, enSilencio: a.conexion == .conectado) }
        }
    }

    /// `enSilencio` no pasa por «Conectando…»: al volver a la app la
    /// conexión casi siempre sigue viva y el parpadeo sólo estorba.
    func conectar(_ id: Aparato.ID, enSilencio: Bool = false) async {
        guard let control = controladores[id] else { return }
        if !enSilencio { cambiar(id) { $0.conexion = .conectando } }
        do {
            try await control.conectar()
            cambiar(id) { $0.conexion = .conectado }
            escuchar(control, de: id)
        } catch ErrorControl.porEmparejar {
            cambiar(id) { $0.conexion = .porEmparejar }
        } catch ErrorControl.esperandoPermiso {
            // La tele pregunta en pantalla; cuando alguien acepte, el
            // controlador avisa con `.listo` por los reportes.
            cambiar(id) { $0.conexion = .esperandoPermiso }
            escuchar(control, de: id)
        } catch {
            cambiar(id) { $0.conexion = .sinConexion(error.localizedDescription) }
        }
    }

    /// Pide a la tele que muestre su código. Regresa el error para la hoja de
    /// emparejamiento, o nil si la tele ya lo está mostrando.
    func pedirCodigo(_ id: Aparato.ID) async -> String? {
        guard let control = controladores[id] as? any Emparejable else { return nil }
        do {
            try await control.pedirCodigo()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func emparejar(_ id: Aparato.ID, codigo: String) async -> String? {
        guard let control = controladores[id] as? any Emparejable else { return nil }
        do {
            try await control.confirmar(codigo: codigo)
            cambiar(id) { $0.conexion = .conectado }
            escuchar(control, de: id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Lo que el aparato reporta manda sobre lo que la app supuso: si alguien
    /// subió el volumen con el control de fábrica, aquí se ve.
    private func escuchar(_ control: any Controlador, de id: Aparato.ID) {
        guard escuchas[id] == nil else { return }
        escuchas[id] = Task { [weak self] in
            for await reporte in control.reportes {
                self?.recibir(reporte, de: id)
            }
        }
    }

    private func recibir(_ reporte: Reporte, de id: Aparato.ID) {
        if case .direccion(let host, let puerto) = reporte {
            // Se recuerda dónde contestó para conectar al instante la próxima vez.
            guard self[id]?.host != host || self[id]?.puerto != puerto else { return }
            cambiar(id) { $0.host = host; $0.puerto = puerto }
            guardar()
            return
        }
        cambiar(id) { a in
            // Sólo cuenta como «estado conocido» lo que dice algo del aparato
            // en sí. Que se abrió una app o que falta emparejar no dice si
            // está prendido, y tomarlo así dejaba «Apagado» en el título.
            switch reporte {
            case .listo, .app, .appPorId, .reproduccionPorEmparejar, .reproduciendo(nil), .direccion: break
            default: a.estadoConocido = true
            }
            switch reporte {
            case .encendido(let si): a.encendido = si
            case .volumen(let v): a.volumen = v
            case .silencio(let si): a.silencio = si
            case .entrada(let clave): a.entrada = clave
            case .modoSonido(let clave): a.modoSonido = clave
            case .app(let nombre): a.appAbierta = nombre
            case .listo: a.conexion = .conectado
            case .reproduciendo(let r):
                a.reproduciendo = r
                // Si algo se está reproduciendo, está prendido: el Apple TV
                // no siempre contesta si lo está, pero esto no deja dudas.
                if r != nil { a.encendido = true }
            case .appPorId(let id):
                // El nombre de la casa si la conoce; si no, el último pedazo
                // del identificador («com.plex.client» → «client» no ayuda,
                // así que mejor el penúltimo: «plex»).
                let partes = id.split(separator: ".")
                a.appAbierta = a.apps.first { $0.id == id }?.nombre
                    ?? (partes.count > 1 ? partes[partes.count - 2] : partes.last).map { $0.capitalized }
            case .reproduccionPorEmparejar(let si): a.reproduccionPorEmparejar = si
            case .direccion: break
            }
        }
    }

    // MARK: - Mandar

    /// Manda la orden al aparato que corresponde. El volumen de una tele
    /// conectada al receptor se desvía al receptor.
    func mandar(_ orden: Orden, a id: Aparato.ID) {
        let destino = destinoDe(orden, desde: id)
        // Se cambia el estado antes de que conteste: en la red de la casa la
        // respuesta tarda y la tecla debe sentirse inmediata.
        aplicar(orden, a: destino)
        guard let control = controladores[destino] else { return }
        Task {
            do {
                try await control.mandar(orden)
            } catch {
                mostrarAviso(error.localizedDescription)
                if case ErrorControl.sinRespuesta = error {
                    cambiar(destino) { $0.conexion = .sinConexion(error.localizedDescription) }
                }
            }
        }
    }

    /// Escribe en el campo abierto de la tele y regresa el error, si hubo,
    /// para mostrarlo en la hoja del teclado: el aviso de abajo queda tapado.
    func escribir(_ texto: String, en id: Aparato.ID) async -> String? {
        guard let control = controladores[id] else { return nil }
        do {
            try await control.mandar(.escribir(texto))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func destinoDe(_ orden: Orden, desde id: Aparato.ID) -> Aparato.ID {
        switch orden {
        case .subirVolumen, .bajarVolumen, .volumen, .silencio:
            self[id]?.volumenEn ?? id
        default:
            id
        }
    }

    private func aplicar(_ orden: Orden, a id: Aparato.ID) {
        cambiar(id) { a in
            switch orden {
            case .encender(let si): a.encendido = si
            case .subirVolumen: a.volumen = min(a.volumen + 1, a.tipo.volumenMaximo); a.silencio = false
            case .bajarVolumen: a.volumen = max(a.volumen - 1, 0)
            case .volumen(let v): a.volumen = min(max(v, 0), a.tipo.volumenMaximo); a.silencio = false
            case .silencio(let si): a.silencio = si
            case .abrirApp(let app): a.appAbierta = app.nombre; a.encendido = true
            case .entrada(let e): a.entrada = e; a.encendido = true
            case .modoSonido(let m): a.modoSonido = m
            default: break
            }
        }
    }

    private func cambiar(_ id: Aparato.ID, _ cambio: (inout Aparato) -> Void) {
        guard let i = aparatos.firstIndex(where: { $0.id == id }) else { return }
        cambio(&aparatos[i])
    }

    private func mostrarAviso(_ texto: String) {
        aviso = texto
        tareaAviso?.cancel()
        tareaAviso = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            aviso = nil
        }
    }
}

extension Casa {
    /// La casa de muestra con controladores puestos a mano, para las pruebas y
    /// las vistas previas: cada tipo usa el que se le pase.
    static func deMuestra(
        onkyo: any Controlador,
        googleTV: any Controlador,
        appleTV: any Controlador,
        lg: any Controlador
    ) -> Casa {
        Casa(aparatos: Catalogo.casaAnterior()) { a in
            switch a.tipo {
            case .onkyo: onkyo
            case .googleTV: googleTV
            case .appleTV: appleTV
            case .lg: lg
            }
        }
    }
}

/// Dónde vive la configuración: un JSON en Application Support. Sin base de
/// datos: son cuatro o cinco aparatos.
struct Almacen {
    let archivo: URL

    struct Guardado: Codable {
        var aparatos: [Aparato]
        var ultimo: Aparato.ID?
    }

    static let predeterminado = Almacen(
        archivo: URL.applicationSupportDirectory.appending(path: "casa.json")
    )

    func cargar() -> Guardado? {
        guard let datos = try? Data(contentsOf: archivo) else { return nil }
        return try? JSONDecoder().decode(Guardado.self, from: datos)
    }

    func guardar(_ g: Guardado) {
        try? FileManager.default.createDirectory(at: archivo.deletingLastPathComponent(), withIntermediateDirectories: true)
        let codificador = JSONEncoder()
        codificador.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? codificador.encode(g).write(to: archivo, options: .atomic)
    }
}
