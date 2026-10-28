import SwiftUI

struct ControlAppleTV: View {
    @Environment(Casa.self) private var casa
    let aparato: Aparato
    @State private var tecladoAbierto = false
    @State private var emparejandoReproduccion = false

    var body: some View {
        VStack(spacing: Espacio.l) {
            if let r = aparato.reproduciendo {
                TarjetaReproduciendo(r: r)
            } else if aparato.reproduccionPorEmparejar {
                // Discreta: el control funciona sin esto; es un extra.
                Button { emparejandoReproduccion = true } label: {
                    HStack(spacing: Espacio.m) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 17, weight: .light))
                            .accessibilityHidden(true)
                        Text("Ver lo que se reproduce")
                            .font(Tipo.cuerpo)
                        Spacer()
                        Text("Emparejar")
                            .font(Tipo.tecla)
                    }
                    .foregroundStyle(Color.hueso)
                    .padding(.horizontal, Espacio.l)
                    .frame(minHeight: 52)
                    .tarjeta(radio: Radio.tecla)
                }
                .buttonStyle(.plain)
            }
            SuperficieTactil(
                mover: { casa.mandar(.mover($0), a: aparato.id) },
                elegir: { casa.mandar(.elegir, a: aparato.id) }
            )
            FilaNavegacion(aparato: aparato, tecladoAbierto: $tecladoAbierto)
            FilaVolumen(aparato: aparato)
            FilaApps(aparato: aparato)
                .padding(.top, Espacio.s)
        }
        .sheet(isPresented: $tecladoAbierto) { HojaTeclado(aparato: aparato) }
        .sheet(isPresented: $emparejandoReproduccion) { HojaEmparejar(id: aparato.id, paraReproduccion: true) }
    }
}

/// La superficie del control del Apple TV: deslizar mueve, tocar elige. Un
/// deslizamiento largo manda varios pasos, como en el control de Apple, para
/// recorrer una fila de pósters sin levantar el dedo.
struct SuperficieTactil: View {
    let mover: (Orden.Direccion) -> Void
    let elegir: () -> Void

    /// Cuánto hay que recorrer para un paso. Menos que esto se siente nervioso;
    /// más obliga a deslizamientos de toda la superficie.
    private let paso: CGFloat = 52

    @State private var dedo: CGPoint?
    /// La ayuda sólo hace falta hasta la primera vez: después estorba.
    @AppStorage("superficieUsada") private var yaLaUso = false
    @State private var ancla: CGPoint?
    @State private var pasos = 0
    @State private var toques = 0
    @Environment(\.accessibilityReduceMotion) private var sinMovimiento

    var body: some View {
        ZStack {
            Reticula(columnas: 6, filas: 5)
                .padding(1)
                .clipShape(.rect(cornerRadius: Radio.tarjeta))
            if let dedo {
                // El punto verde es la señal de la marca: sigue al dedo.
                Circle()
                    .fill(Color.verde)
                    .frame(width: 14, height: 14)
                    .background {
                        Circle().fill(Color.verde.opacity(0.18)).frame(width: 64, height: 64)
                    }
                    .position(dedo)
                    .transition(.opacity)
            }
            VStack {
                Spacer()
                Text("DESLIZA PARA MOVER · TOCA PARA ELEGIR")
                    .font(Tipo.etiqueta)
                    .tracking(1)
                    .foregroundStyle(Color.grisTexto)
                    .multilineTextAlignment(.center)
                    // Fondo de panel para que la retícula no le pase por encima al texto.
                    .padding(.horizontal, Espacio.s)
                    .padding(.vertical, Espacio.xs)
                    .background(Color.panel)
                    .padding(.bottom, Espacio.l)
                    .opacity(dedo == nil && !yaLaUso ? 1 : 0)
            }
            .allowsHitTesting(false)
        }
        .aspectRatio(Proporcion.superficie, contentMode: .fit)
        .tarjeta()
        .contentShape(.rect(cornerRadius: Radio.tarjeta))
        .gesture(arrastre)
        .sensoryFeedback(.selection, trigger: pasos)
        .sensoryFeedback(.impact(weight: .light), trigger: toques)
        .animation(sinMovimiento ? nil : .easeOut(duration: 0.15), value: dedo == nil)
        .accessibilityElement()
        .accessibilityLabel("Superficie del control")
        .accessibilityHint("Desliza para moverte en la tele, toca dos veces para elegir")
        .accessibilityAction { elegir() }
        .accessibilityAction(named: "Arriba") { mover(.arriba) }
        .accessibilityAction(named: "Abajo") { mover(.abajo) }
        .accessibilityAction(named: "Izquierda") { mover(.izquierda) }
        .accessibilityAction(named: "Derecha") { mover(.derecha) }
    }

    private var arrastre: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { valor in
                dedo = valor.location
                let inicio = ancla ?? valor.startLocation
                let dx = valor.location.x - inicio.x
                let dy = valor.location.y - inicio.y
                guard max(abs(dx), abs(dy)) >= paso else {
                    if ancla == nil { ancla = inicio }
                    return
                }
                // Gana el eje dominante: en diagonal nadie quiere ir en diagonal.
                if abs(dx) > abs(dy) {
                    mover(dx > 0 ? .derecha : .izquierda)
                } else {
                    mover(dy > 0 ? .abajo : .arriba)
                }
                pasos += 1
                ancla = valor.location
            }
            .onEnded { valor in
                let recorrido = hypot(valor.translation.width, valor.translation.height)
                // Un toque es un toque aunque el dedo se haya movido un poco.
                if recorrido < 12 {
                    toques += 1
                    elegir()
                }
                yaLaUso = true
                dedo = nil
                ancla = nil
            }
    }
}
