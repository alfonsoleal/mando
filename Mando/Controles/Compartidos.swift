import SwiftUI

/// Atrás, inicio, reproducir y teclado: lo mismo en las dos teles, en el mismo
/// lugar, para que el pulgar no tenga que aprender dos controles.
struct FilaNavegacion: View {
    @Environment(Casa.self) private var casa
    let aparato: Aparato
    @Binding var tecladoAbierto: Bool

    var body: some View {
        HStack(spacing: Espacio.m) {
            Tecla("Atrás", icono: "chevron.backward") { casa.mandar(.atras, a: aparato.id) }
            Tecla("Inicio", icono: "house") { casa.mandar(.inicio, a: aparato.id) }
            Tecla("Reproducir o pausar", icono: "playpause") { casa.mandar(.playPausa, a: aparato.id) }
            Tecla("Teclado", icono: "keyboard") { tecladoAbierto = true }
        }
    }
}

/// Volumen de una tele: si lo lleva el receptor, muestra y mueve el del receptor.
struct FilaVolumen: View {
    @Environment(Casa.self) private var casa
    let aparato: Aparato

    var body: some View {
        let dueno = casa[casa.destinoDe(.subirVolumen, desde: aparato.id)] ?? aparato
        HStack(spacing: Espacio.m) {
            if !dueno.volumenCiego {
                Tecla("Silencio", icono: dueno.silencio ? "speaker.slash" : "speaker") {
                    casa.mandar(.silencio(!dueno.silencio), a: aparato.id)
                }
                .frame(width: 64)
            }
            HStack(spacing: 0) {
                Tecla("Bajar volumen", icono: "minus", repetir: true) {
                    casa.mandar(.bajarVolumen, a: aparato.id)
                }
                VStack(spacing: 2) {
                    Text(dueno.silencio || !dueno.estadoConocido || dueno.volumenCiego ? "—" : "\(dueno.volumen)")
                        .font(Tipo.dato)
                        .foregroundStyle(Color.hueso)
                        .contentTransition(.numericText(value: Double(dueno.volumen)))
                        .monospacedDigit()
                    // Debajo del número va de quién es el volumen («LG»,
                    // «ONKYO»): se lee justo donde se usa, no en el encabezado.
                    Text(dueno.id == aparato.id ? "VOL" : dueno.nombre.replacingOccurrences(of: "Tele ", with: "").uppercased())
                        .font(Tipo.etiqueta)
                        .foregroundStyle(Color.grisTexto)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: 64)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Volumen")
                .accessibilityValue(dueno.volumenCiego ? "El de la tele" : dueno.silencio ? "Silencio" : "\(dueno.volumen)")
                .accessibilityAdjustableAction { dir in
                    casa.mandar(dir == .increment ? .subirVolumen : .bajarVolumen, a: aparato.id)
                }
                Tecla("Subir volumen", icono: "plus", repetir: true) {
                    casa.mandar(.subirVolumen, a: aparato.id)
                }
            }
            .animation(.snappy(duration: 0.2), value: dueno.volumen)
        }
    }
}

struct FilaApps: View {
    @Environment(Casa.self) private var casa
    let aparato: Aparato

    var body: some View {
        // Sin etiqueta «Apps»: las fichas con nombres de apps se explican solas.
        if !aparato.appsVisibles.isEmpty {
        VStack(alignment: .leading, spacing: Espacio.m) {
            ScrollView(.horizontal) {
                HStack(spacing: Espacio.s) {
                    ForEach(aparato.appsVisibles) { app in
                        Ficha(texto: app.nombre, activa: app.nombre == aparato.appAbierta) {
                            casa.mandar(.abrirApp(app), a: aparato.id)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            // Las fichas llegan al borde de la pantalla para que se note que hay más.
            .padding(.horizontal, -Espacio.xl)
            .contentMargins(.horizontal, Espacio.xl, for: .scrollContent)
        }
        }
    }
}

/// Para buscar en Netflix o YouTube sin pasar letra por letra con las flechas.
/// Lo escrito aparece en la tele mientras se teclea.
struct HojaTeclado: View {
    @Environment(Casa.self) private var casa
    @Environment(\.dismiss) private var cerrar
    let aparato: Aparato

    @State private var texto = ""
    @State private var error: String?
    @FocusState private var enfocado: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Espacio.l) {
            Kicker(texto: "Escribir en \(aparato.nombre)")
            TextField("Lo que buscas", text: $texto)
                .font(Tipo.cuerpo)
                .foregroundStyle(Color.hueso)
                .autocorrectionDisabled()
                .padding(.horizontal, Espacio.l)
                .frame(minHeight: 52)
                .tarjeta(radio: Radio.tecla)
                .focused($enfocado)
                .submitLabel(.done)
                .onSubmit { cerrar() }
            if let error {
                HStack(alignment: .top, spacing: Espacio.m) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(Color.ambar)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(Tipo.cuerpo)
                        .foregroundStyle(Color.hueso)
                }
            } else {
                Text("Abre la búsqueda en la tele.")
                    .font(Tipo.etiqueta)
                    .foregroundStyle(Color.grisTexto)
            }
        }
        .padding(Espacio.xl)
        .presentationDetents([.height(240)])
        .presentationBackground(Color.carbon)
        .onAppear { enfocado = true }
        // Cada cambio cancela al anterior: con una pausa de 250 ms se manda
        // lo escrito al dejar de teclear, no una orden por letra.
        .task(id: texto) {
            guard !texto.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            error = await casa.escribir(texto, en: aparato.id)
        }
    }
}
