import SwiftUI

// MAQUETA del deck de la Mac: la pantalla con datos de muestra. Los botones
// todavía no hacen nada; cuando exista Mando para Mac, `Deck` se llena con lo
// que mande la Mac y cada botón se vuelve una Orden.

struct BotonDeck: Identifiable, Hashable {
    let id = UUID()
    let icono: String
    let nombre: String
    /// Lo que hace, en mono: el atajo («⌘B»), la app que abre o el Atajo.
    let detalle: String
}

struct PaginaDeck: Identifiable, Hashable {
    let id = UUID()
    let nombre: String
    /// La app de la Mac que pone esta página al frente sola.
    let app: String?
    let botones: [BotonDeck]
}

/// La Mac como un aparato más: una botonera que cambia de página según la
/// app que esté al frente, y abajo la música y el volumen de la Mac.
struct ControlMac: View {
    let paginas: [PaginaDeck]
    /// La app al frente en la Mac; su página se elige sola.
    let alFrente: String

    @State private var elegida: PaginaDeck.ID?
    @State private var toques = 0
    @State private var volumen = 46

    private var automatica: PaginaDeck? { paginas.first { $0.app == alFrente } }
    private var actual: PaginaDeck? {
        paginas.first { $0.id == elegida } ?? automatica ?? paginas.first
    }

    private let columnas = Array(repeating: GridItem(.flexible(), spacing: Espacio.m), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.xl) {
            selectorPaginas
            if let actual {
                LazyVGrid(columns: columnas, spacing: Espacio.m) {
                    ForEach(actual.botones) { boton in
                        BotonDelDeck(boton: boton) { toques += 1 }
                    }
                }
                .id(actual.id)
            }
            musica
        }
    }

    /// Las páginas como fichas. La de la app al frente lleva «AUTO»: si la
    /// mano eligió otra, al cambiar de app en la Mac se vuelve a la automática.
    private var selectorPaginas: some View {
        VStack(alignment: .leading, spacing: Espacio.m) {
            Kicker(texto: "Páginas", punto: false)
            ScrollView(.horizontal) {
                HStack(spacing: Espacio.s) {
                    ForEach(paginas) { p in
                        Ficha(texto: p.app == alFrente ? "\(p.nombre) · auto" : p.nombre, activa: p.id == actual?.id) {
                            elegida = p.id
                        }
                    }
                    Button {} label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .light))
                            .foregroundStyle(Color.grisTexto)
                            .frame(width: 44, height: 44)
                            .overlay { Circle().strokeBorder(Color.hilo, style: StrokeStyle(lineWidth: 1, dash: [3, 3])) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Agregar página")
                }
            }
            .scrollIndicators(.hidden)
            .padding(.horizontal, -Espacio.xl)
            .contentMargins(.horizontal, Espacio.xl, for: .scrollContent)
        }
    }

    private var musica: some View {
        VStack(alignment: .leading, spacing: Espacio.l) {
            Kicker(texto: "Música y volumen de la Mac", punto: false)
            HStack(spacing: Espacio.m) {
                Tecla("Anterior", icono: "backward") {}
                Tecla("Reproducir o pausar", icono: "playpause") {}
                Tecla("Siguiente", icono: "forward") {}
            }
            HStack(alignment: .center, spacing: Espacio.l) {
                Text("\(volumen)")
                    .font(Tipo.dato)
                    .foregroundStyle(Color.hueso)
                    .monospacedDigit()
                    .frame(width: 32, alignment: .leading)
                ReglaVolumen(valor: volumen, maximo: 100) { volumen = $0 }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: toques)
    }
}

/// Un botón del deck: cuadrado, ícono arriba, nombre y lo que hace en mono.
/// Más grande que una tecla del control porque aquí se lee antes de apretar.
struct BotonDelDeck: View {
    let boton: BotonDeck
    let accion: () -> Void

    var body: some View {
        Button(action: accion) {
            VStack(alignment: .leading, spacing: Espacio.s) {
                Image(systemName: boton.icono)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.hueso)
                    .frame(height: 28, alignment: .leading)
                Spacer(minLength: 0)
                Text(boton.nombre)
                    .font(Tipo.tecla)
                    .foregroundStyle(Color.hueso)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                Text(boton.detalle.uppercased())
                    .font(Tipo.etiqueta)
                    .tracking(0.5)
                    .foregroundStyle(Color.grisTexto)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(Espacio.m)
            // Altura fija: un nombre de dos líneas no debe hacer más alta su
            // fila; la retícula pareja es la que deja encontrar el botón a ciegas.
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 124)
            .contentShape(.rect(cornerRadius: Radio.tecla))
        }
        .buttonStyle(EstiloTecla())
        .accessibilityLabel(boton.nombre)
        .accessibilityHint(boton.detalle)
    }
}

// MARK: - Datos de muestra

enum MaquetaDeck {
    static let paginas: [PaginaDeck] = [
        PaginaDeck(nombre: "Final Cut", app: "Final Cut Pro", botones: [
            BotonDeck(icono: "scissors", nombre: "Cortar", detalle: "⌘B"),
            BotonDeck(icono: "bookmark", nombre: "Marcador", detalle: "M"),
            BotonDeck(icono: "playpause", nombre: "Reproducir", detalle: "Espacio"),
            BotonDeck(icono: "arrow.uturn.backward", nombre: "Deshacer", detalle: "⌘Z"),
            BotonDeck(icono: "arrow.up.left.and.arrow.down.right", nombre: "Ajustar línea", detalle: "⇧Z"),
            BotonDeck(icono: "textformat", nombre: "Título", detalle: "⌃T"),
            BotonDeck(icono: "paintpalette", nombre: "Color", detalle: "⌘6"),
            BotonDeck(icono: "speaker.slash", nombre: "Silenciar clip", detalle: "⌃−"),
            BotonDeck(icono: "square.and.arrow.up", nombre: "Exportar", detalle: "⌘E"),
        ]),
        PaginaDeck(nombre: "Affinity", app: "Affinity Designer", botones: [
            BotonDeck(icono: "cursorarrow", nombre: "Mover", detalle: "V"),
            BotonDeck(icono: "pencil.tip", nombre: "Pluma", detalle: "P"),
            BotonDeck(icono: "textformat.abc", nombre: "Texto", detalle: "T"),
            BotonDeck(icono: "square.on.square", nombre: "Duplicar", detalle: "⌘J"),
            BotonDeck(icono: "rectangle.3.group", nombre: "Agrupar", detalle: "⌘G"),
            BotonDeck(icono: "square.and.arrow.up", nombre: "Exportar", detalle: "⌥⇧⌘W"),
        ]),
        PaginaDeck(nombre: "General", app: nil, botones: [
            BotonDeck(icono: "safari", nombre: "Safari Trabajo", detalle: "Perfil"),
            BotonDeck(icono: "camera.viewfinder", nombre: "Captura", detalle: "⌘⇧4"),
            BotonDeck(icono: "rectangle.3.group", nombre: "Mission Control", detalle: "⌃↑"),
            BotonDeck(icono: "film", nombre: "Final Cut Pro", detalle: "Abrir app"),
            BotonDeck(icono: "folder", nombre: "Clientes", detalle: "~/Trabajo"),
            BotonDeck(icono: "moon", nombre: "Enfoque", detalle: "Atajo"),
            BotonDeck(icono: "lock", nombre: "Bloquear", detalle: "⌃⌘Q"),
        ]),
    ]
}

#if DEBUG
/// La pantalla completa de la maqueta, con el selector y el encabezado como
/// quedarían con la Mac en la casa. Se abre con el argumento `-maquetaDeck`.
struct MaquetaPantallaDeck: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal) {
                    HStack(spacing: Espacio.s) {
                        Text("ESTUDIO")
                            .font(Tipo.etiqueta).tracking(1).foregroundStyle(Color.grisTexto)
                        Ficha(texto: "Mac", activa: true) {}
                        Ficha(texto: "Google TV") {}
                        Ficha(texto: "Onkyo") {}
                        Text("SALA")
                            .font(Tipo.etiqueta).tracking(1).foregroundStyle(Color.grisTexto)
                            .padding(.leading, Espacio.m)
                        Ficha(texto: "Apple TV") {}
                        Ficha(texto: "Tele LG") {}
                    }
                    .padding(.horizontal, Espacio.xl)
                }
                .scrollIndicators(.hidden)
                BotonAjustes {}
                    .padding(.trailing, Espacio.l)
            }
            .padding(.top, Espacio.s)
            ScrollView {
                VStack(alignment: .leading, spacing: Espacio.xl) {
                    HStack(alignment: .top, spacing: Espacio.l) {
                        VStack(alignment: .leading, spacing: Espacio.m) {
                            Kicker(texto: "Estudio · Mac")
                            Text("En \(Text("Final Cut").font(Tipo.acento).foregroundStyle(Color.verde))")
                                .font(Tipo.titulo)
                                .foregroundStyle(Color.hueso)
                                .lineLimit(1)
                            Text("CONECTADO · MAC MINI")
                                .font(Tipo.etiqueta).tracking(1).foregroundStyle(Color.grisTexto)
                        }
                        Spacer(minLength: 0)
                        // En la Mac, el botón de la esquina la bloquea en vez de apagarla.
                        Image(systemName: "lock")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.hueso)
                            .frame(width: 52, height: 52)
                            .background(Color.panel, in: .circle)
                            .overlay { Circle().strokeBorder(Color.hilo) }
                    }
                    ControlMac(paginas: MaquetaDeck.paginas, alFrente: "Final Cut Pro")
                }
                .padding(.horizontal, Espacio.xl)
                .padding(.top, Espacio.xl)
                .padding(.bottom, Espacio.xxl)
            }
        }
        .background { FondoCarbon() }
    }
}
#endif

#Preview("Deck") {
    ScrollView {
        VStack(alignment: .leading, spacing: Espacio.xl) {
            ControlMac(paginas: MaquetaDeck.paginas, alFrente: "Final Cut Pro")
        }
        .padding(Espacio.xl)
    }
    .background { FondoCarbon() }
    .environment(Casa(aparatos: []))
}
