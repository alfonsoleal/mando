import SwiftUI

/// Carbón con el grano de la marca, para que el negro no se vea plano.
struct FondoCarbon: View {
    var body: some View {
        Color.carbon
            .overlay {
                Image("Grano")
                    .resizable(resizingMode: .tile)
                    .opacity(0.9)
            }
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Punto verde y texto en mono: la señal con la que la marca abre cada bloque.
struct Kicker: View {
    let texto: String
    var punto = true

    var body: some View {
        HStack(spacing: Espacio.s) {
            if punto {
                Circle().fill(Color.verde).frame(width: 6, height: 6)
            }
            Text(texto.uppercased())
                .font(Tipo.etiqueta)
                .tracking(1.2)
                .foregroundStyle(Color.grisTexto)
        }
    }
}

extension View {
    /// Tarjeta de la marca: panel con hilo, sin sombra. El destacado cambia el
    /// hilo a verde; se usa en una sola cosa por pantalla.
    func tarjeta(radio: CGFloat = Radio.tarjeta, destacada: Bool = false) -> some View {
        background(Color.panel, in: .rect(cornerRadius: radio))
            .overlay {
                RoundedRectangle(cornerRadius: radio)
                    .strokeBorder(destacada ? Color.verde : Color.hilo, lineWidth: 1)
            }
    }
}

/// Una tecla del control. Vibra al tocarla porque en un control remoto se
/// mira la tele, no el teléfono: el pulgar necesita saber que sí apretó.
struct Tecla<Contenido: View>: View {
    let etiqueta: String
    var alto: CGFloat = 56
    var repetir = false
    let accion: () -> Void
    @ViewBuilder let contenido: () -> Contenido

    @State private var toques = 0

    var body: some View {
        Button {
            toques += 1
            accion()
        } label: {
            contenido()
                .frame(maxWidth: .infinity, minHeight: alto)
                .contentShape(.rect(cornerRadius: Radio.tecla))
        }
        .buttonStyle(EstiloTecla())
        .buttonRepeatBehavior(repetir ? .enabled : .disabled)
        .sensoryFeedback(.impact(weight: .light), trigger: toques)
        .accessibilityLabel(etiqueta)
    }
}

extension Tecla where Contenido == TeclaIcono {
    init(_ etiqueta: String, icono: String, alto: CGFloat = 56, repetir: Bool = false, accion: @escaping () -> Void) {
        self.init(etiqueta: etiqueta, alto: alto, repetir: repetir, accion: accion) {
            TeclaIcono(icono: icono)
        }
    }
}

struct TeclaIcono: View {
    let icono: String
    var body: some View {
        Image(systemName: icono)
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(Color.hueso)
    }
}

struct EstiloTecla: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Color.panelActivo : Color.panel,
                in: .rect(cornerRadius: Radio.tecla)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radio.tecla)
                    .strokeBorder(configuration.isPressed ? Color.grisTrazo : Color.hilo, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// Retícula de la marca: columnas punteadas con cruces en las intersecciones.
/// Decora la superficie táctil sin competir con el dedo.
struct Reticula: View {
    var columnas = 6
    var filas = 6

    var body: some View {
        Canvas { ctx, tam in
            let trazo = StrokeStyle(lineWidth: 0.5, dash: [1, 4])
            let dx = tam.width / CGFloat(columnas)
            let dy = tam.height / CGFloat(filas)
            for c in 1..<columnas {
                var linea = Path()
                linea.move(to: CGPoint(x: CGFloat(c) * dx, y: 0))
                linea.addLine(to: CGPoint(x: CGFloat(c) * dx, y: tam.height))
                ctx.stroke(linea, with: .color(.grisTrazo), style: trazo)
            }
            for c in 1..<columnas {
                for f in 1..<filas {
                    let p = CGPoint(x: CGFloat(c) * dx, y: CGFloat(f) * dy)
                    var cruz = Path()
                    cruz.move(to: CGPoint(x: p.x - 3, y: p.y))
                    cruz.addLine(to: CGPoint(x: p.x + 3, y: p.y))
                    cruz.move(to: CGPoint(x: p.x, y: p.y - 3))
                    cruz.addLine(to: CGPoint(x: p.x, y: p.y + 3))
                    ctx.stroke(cruz, with: .color(.grisTrazo), lineWidth: 0.75)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Ficha redonda con texto en mono: apps, modos de sonido, aparatos.
struct Ficha: View {
    let texto: String
    var activa = false
    let accion: () -> Void

    @State private var toques = 0

    var body: some View {
        Button {
            toques += 1
            accion()
        } label: {
            Text(texto.uppercased())
                .font(Tipo.etiqueta)
                .tracking(1)
                .foregroundStyle(activa ? Color.hueso : Color.grisTexto)
                .padding(.horizontal, Espacio.l)
                .frame(minHeight: 44)
                .background(activa ? Color.panelActivo : Color.panel, in: .capsule)
                .overlay {
                    Capsule().strokeBorder(activa ? Color.hueso.opacity(0.6) : Color.hilo, lineWidth: 1)
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: toques)
        .accessibilityAddTraits(activa ? .isSelected : [])
    }
}
