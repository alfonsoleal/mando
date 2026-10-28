import SwiftUI

/// Lo que se está viendo, como en la pantalla de bloqueo del iPhone: portada,
/// título, de qué serie es y cuánto falta. La barra avanza sola cada segundo
/// a partir de la última posición que dio la tele.
struct TarjetaReproduciendo: View {
    let r: Reproduciendo

    var body: some View {
        HStack(spacing: Espacio.l) {
            portada
            VStack(alignment: .leading, spacing: Espacio.xs) {
                Text(r.titulo)
                    .font(Tipo.tecla)
                    .foregroundStyle(Color.hueso)
                    .lineLimit(1)
                if let detalle = r.detalle {
                    Text(detalle.uppercased())
                        .font(Tipo.etiqueta)
                        .tracking(0.5)
                        .foregroundStyle(Color.grisTexto)
                        .lineLimit(1)
                }
                if r.duracion != nil, r.transcurrido != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { contexto in
                        avance(contexto.date)
                    }
                    .padding(.top, Espacio.xs)
                }
            }
        }
        .padding(Espacio.m)
        .tarjeta(radio: Radio.tecla)
        .accessibilityElement(children: .combine)
    }

    private var portada: some View {
        Group {
            if let datos = r.portada, let imagen = UIImage(data: datos) {
                Image(uiImage: imagen).resizable().scaledToFill()
            } else {
                Image(systemName: "play.rectangle")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.grisTexto)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.panelActivo)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(.rect(cornerRadius: Radio.tecla - Espacio.s))
        .accessibilityHidden(true)
    }

    private func avance(_ ahora: Date) -> some View {
        let total = r.duracion ?? 1
        let va = r.transcurridoAhora(ahora) ?? 0
        return VStack(spacing: Espacio.xs) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.hilo)
                    Capsule().fill(Color.hueso)
                        .frame(width: geo.size.width * CGFloat(min(max(va / total, 0), 1)))
                }
            }
            .frame(height: 3)
            HStack {
                Text(Self.tiempo(va))
                Spacer()
                Text("−" + Self.tiempo(total - va))
            }
            .font(Tipo.etiqueta)
            .foregroundStyle(Color.grisTexto)
            .monospacedDigit()
        }
        .accessibilityElement()
        .accessibilityLabel("Avance")
        .accessibilityValue("\(Self.tiempo(va)) de \(Self.tiempo(total))")
    }

    static func tiempo(_ s: TimeInterval) -> String {
        let t = Int(max(s, 0))
        return t >= 3600
            ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}
