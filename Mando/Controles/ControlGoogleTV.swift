import SwiftUI

struct ControlGoogleTV: View {
    @Environment(Casa.self) private var casa
    let aparato: Aparato
    @State private var tecladoAbierto = false

    var body: some View {
        VStack(spacing: Espacio.l) {
            Cruceta(
                mover: { casa.mandar(.mover($0), a: aparato.id) },
                elegir: { casa.mandar(.elegir, a: aparato.id) }
            )
            FilaNavegacion(aparato: aparato, tecladoAbierto: $tecladoAbierto)
            FilaVolumen(aparato: aparato)
            FilaApps(aparato: aparato)
                .padding(.top, Espacio.s)
        }
        .sheet(isPresented: $tecladoAbierto) { HojaTeclado(aparato: aparato) }
    }
}

/// La cruceta del control de Google TV. Va en el mismo cuadrado que la
/// superficie del Apple TV para que cambiar de tele no mueva lo demás.
struct Cruceta: View {
    let mover: (Orden.Direccion) -> Void
    let elegir: () -> Void

    var body: some View {
        GeometryReader { geo in
            let lado = min(geo.size.width, geo.size.height)
            let centro = lado * 0.38
            ZStack {
                Circle()
                    .strokeBorder(Color.hilo, lineWidth: 1)
                    .background(Color.panel, in: .circle)
                    .frame(width: lado * 0.94, height: lado * 0.94)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    flecha(.arriba, "chevron.up", "Arriba")
                    HStack(spacing: 0) {
                        flecha(.izquierda, "chevron.left", "Izquierda")
                        BotonOK(diametro: centro, accion: elegir)
                        flecha(.derecha, "chevron.right", "Derecha")
                    }
                    flecha(.abajo, "chevron.down", "Abajo")
                }
            }
            .frame(width: lado, height: lado)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background {
            Reticula(columnas: 6, filas: 5)
                .padding(1)
                .clipShape(.rect(cornerRadius: Radio.tarjeta))
        }
        .aspectRatio(Proporcion.superficie, contentMode: .fit)
        .tarjeta()
    }

    private func flecha(_ dir: Orden.Direccion, _ icono: String, _ nombre: String) -> some View {
        BotonFlecha(icono: icono, nombre: nombre) { mover(dir) }
    }
}

private struct BotonFlecha: View {
    let icono: String
    let nombre: String
    let accion: () -> Void
    @State private var toques = 0

    var body: some View {
        Button {
            toques += 1
            accion()
        } label: {
            Image(systemName: icono)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.hueso)
                // 88 pt: con la tele enfrente el pulgar no apunta, cae.
                .frame(width: 88, height: 88)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .sensoryFeedback(.selection, trigger: toques)
        .accessibilityLabel(nombre)
    }
}

private struct BotonOK: View {
    let diametro: CGFloat
    let accion: () -> Void
    @State private var toques = 0

    var body: some View {
        Button {
            toques += 1
            accion()
        } label: {
            Text("OK")
                .font(Tipo.dato)
                .tracking(1)
                .foregroundStyle(Color.hueso)
                .frame(width: diametro, height: diametro)
        }
        .buttonStyle(EstiloOK())
        .sensoryFeedback(.impact(weight: .light), trigger: toques)
        .accessibilityLabel("Elegir")
    }
}

private struct EstiloOK: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.panelActivo : Color.carbon, in: .circle)
            .overlay {
                // Al apretar, el anillo se vuelve verde: la única señal de la pantalla.
                Circle().strokeBorder(configuration.isPressed ? Color.verde : Color.hilo, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
