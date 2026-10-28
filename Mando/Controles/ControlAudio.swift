import SwiftUI

/// El receptor y la tele LG: el volumen es la cifra protagonista. Las
/// entradas y los modos de sonido, si el aparato los tiene, se ven todos, sin
/// menú.
struct ControlAudio: View {
    @Environment(Casa.self) private var casa
    let aparato: Aparato

    private let columnas = [GridItem(.flexible(), spacing: Espacio.m), GridItem(.flexible(), spacing: Espacio.m)]

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.xl) {
            volumen
            if !aparato.entradasVisibles.isEmpty {
                VStack(alignment: .leading, spacing: Espacio.m) {
                    Kicker(texto: "Entrada", punto: false)
                    LazyVGrid(columns: columnas, spacing: Espacio.m) {
                        ForEach(aparato.entradasVisibles) { entrada in
                            TarjetaEntrada(entrada: entrada, activa: entrada.clave == aparato.entrada) {
                                casa.mandar(.entrada(entrada.clave), a: aparato.id)
                            }
                        }
                    }
                }
            }
            if !aparato.modosVisibles.isEmpty {
                VStack(alignment: .leading, spacing: Espacio.m) {
                    Kicker(texto: "Modo de sonido", punto: false)
                    ScrollView(.horizontal) {
                        HStack(spacing: Espacio.s) {
                            ForEach(aparato.modosVisibles) { modo in
                                Ficha(texto: modo.nombre, activa: modo.clave == aparato.modoSonido) {
                                    casa.mandar(.modoSonido(modo.clave), a: aparato.id)
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .padding(.horizontal, -Espacio.xl)
                    .contentMargins(.horizontal, Espacio.xl, for: .scrollContent)
                }
            }
        }
    }

    private var volumen: some View {
        VStack(alignment: .leading, spacing: Espacio.l) {
            HStack(alignment: .lastTextBaseline) {
                Text(aparato.silencio || !aparato.estadoConocido ? "—" : "\(aparato.volumen)")
                    .font(Tipo.cifra)
                    .foregroundStyle(aparato.silencio || !aparato.estadoConocido ? Color.grisTexto : Color.hueso)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(aparato.volumen)))
                    .animation(.snappy(duration: 0.2), value: aparato.volumen)
                Text(aparato.silencio ? "SILENCIO" : "/ \(aparato.tipo.volumenMaximo)")
                    .font(Tipo.etiqueta)
                    .tracking(1)
                    .foregroundStyle(Color.grisTexto)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Volumen")
            .accessibilityValue(aparato.silencio ? "Silencio" : "\(aparato.volumen) de \(aparato.tipo.volumenMaximo)")

            ReglaVolumen(valor: aparato.volumen, maximo: aparato.tipo.volumenMaximo) {
                casa.mandar(.volumen($0), a: aparato.id)
            }
            // Sin estado real la regla no tiene dónde poner el punto.
            .opacity(aparato.estadoConocido ? 1 : 0.3)
            .disabled(!aparato.estadoConocido)

            HStack(spacing: Espacio.m) {
                Tecla("Silencio", icono: aparato.silencio ? "speaker.slash" : "speaker") {
                    casa.mandar(.silencio(!aparato.silencio), a: aparato.id)
                }
                Tecla("Bajar volumen", icono: "minus", repetir: true) {
                    casa.mandar(.bajarVolumen, a: aparato.id)
                }
                Tecla("Subir volumen", icono: "plus", repetir: true) {
                    casa.mandar(.subirVolumen, a: aparato.id)
                }
            }
        }
    }
}

/// Las marcas de regla de la marca, convertidas en control: el tramo recorrido
/// en hueso y el punto verde donde está el volumen.
struct ReglaVolumen: View {
    let valor: Int
    let maximo: Int
    let cambiar: (Int) -> Void

    @State private var arrastrando: Int?

    var body: some View {
        let mostrado = arrastrando ?? valor
        GeometryReader { geo in
            let ancho = geo.size.width
            let x = ancho * CGFloat(mostrado) / CGFloat(maximo)
            ZStack(alignment: .leading) {
                Canvas { ctx, tam in
                    for i in stride(from: 0, through: maximo, by: 2) {
                        let px = tam.width * CGFloat(i) / CGFloat(maximo)
                        let larga = i % 10 == 0
                        let alto: CGFloat = larga ? 16 : 8
                        var marca = Path()
                        marca.move(to: CGPoint(x: px, y: tam.height / 2 - alto / 2))
                        marca.addLine(to: CGPoint(x: px, y: tam.height / 2 + alto / 2))
                        let color: Color = i <= mostrado ? .hueso : .grisTrazo
                        ctx.stroke(marca, with: .color(color), lineWidth: larga ? 1.25 : 0.75)
                    }
                }
                Circle()
                    .fill(Color.verde)
                    .frame(width: 12, height: 12)
                    .offset(x: x - 6)
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let nuevo = Int((v.location.x / ancho * CGFloat(maximo)).rounded())
                        arrastrando = min(max(nuevo, 0), maximo)
                    }
                    .onEnded { _ in
                        // Se manda al soltar: arrastrar de 20 a 60 no debe
                        // disparar cuarenta órdenes al receptor.
                        if let arrastrando { cambiar(arrastrando) }
                        arrastrando = nil
                    }
            )
            .sensoryFeedback(.selection, trigger: mostrado / 5)
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Volumen")
        .accessibilityValue("\(valor)")
        .accessibilityAdjustableAction { dir in
            cambiar(dir == .increment ? min(valor + 2, maximo) : max(valor - 2, 0))
        }
    }
}

/// Una entrada del receptor: sólo el nombre de la casa («Google TV»). La
/// etiqueta impresa en el receptor (CBL/SAT) vive en ajustes; aquí era una
/// segunda línea en cada tarjeta que no ayudaba a elegir.
struct TarjetaEntrada: View {
    let entrada: Entrada
    let activa: Bool
    let accion: () -> Void
    @State private var toques = 0

    var body: some View {
        Button {
            toques += 1
            accion()
        } label: {
            HStack(spacing: Espacio.s) {
                Text(entrada.nombre)
                    .font(Tipo.cuerpo)
                    .foregroundStyle(Color.hueso)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                if activa {
                    Circle().fill(Color.hueso).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, Espacio.l)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(activa ? Color.panelActivo : Color.panel, in: .rect(cornerRadius: Radio.tecla))
            .overlay {
                RoundedRectangle(cornerRadius: Radio.tecla)
                    .strokeBorder(activa ? Color.hueso.opacity(0.6) : Color.hilo, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: Radio.tecla))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: toques)
        .accessibilityLabel("\(entrada.nombre), \(entrada.etiqueta)")
        .accessibilityAddTraits(activa ? .isSelected : [])
    }
}
