# Mando

Un control universal para iPhone y iPad: Apple TV, Google TV, receptores Onkyo y teles LG en una sola app, configurable
desde la misma app. Más adelante, la Mac y las rutinas («Ver película»).

| Lo que hace | Lo que no hace (todavía) |
|---|---|
| **Se configura desde la app**: busca en la red los Apple TV, Google TV, Onkyo y teles LG, y los va mostrando conforme aparecen | Prender la LG apagada (Wake on LAN pide un permiso especial en iOS) |
| Por aparato: nombre, cuarto, a quién manda su volumen, la entrada del receptor que se elige sola, entradas y modos (renombrar, ocultar, ordenar), apps, IP a mano, olvidar emparejamiento y quitar | |
| Guarda la casa en el teléfono (`casa.json`) y recuerda el último aparato y dónde contestó cada uno; si cambia de IP, lo vuelve a buscar | Rutinas («Ver película»), Mac, widgets, Centro de Control, Apple Watch |
| **Apple TV** por Companion: PIN de 4 dígitos, verificación con firmas en cada conexión, teclas, prender, dormir y abrir apps; trae su lista real de apps | La voz de los controles |
| **Google TV** por el control remoto v2: código de 6 caracteres, teclas, apps, escribir en la búsqueda y estado en vivo | |
| **Onkyo** por eISCP: volumen, silencio, entradas, modos y estado en vivo, también lo que se haga con su control | |
| **Tele LG** por SSAP: permiso en pantalla una vez; volumen, silencio, apagar y estado en vivo | |
| Selector agrupado por cuarto; al volver a la app revisa las conexiones para que la primera tecla no falle | |
| Vibración en cada tecla, VoiceOver con acciones de dirección, Dynamic Type | |

## Cómo está armado

```
Mando/
├── project.yml              xcodegen genera Mando.xcodeproj
└── Mando/
    ├── Marca/               tema Carbón: tokens y componentes
    ├── Modelo/              Aparato (configuración + estado), Orden, Casa y Almacen,
    │                        Catalogo (con qué llega cada tipo y la casa de muestra)
    ├── Conexion/            Controlador y TCP/TLS; EISCP y ControladorOnkyo;
│                        Protobuf, Certificado, AndroidTV y ControladorGoogleTV;
│                        EnteroGrande, SRP, OPACK (y TLV8), HAP y ControladorAppleTV
    ├── Pantallas/           Raiz (selector, primer uso), Ajustes (agregar, editar),
    │                        Emparejar
    ├── Controles/           un archivo por tipo de control y lo compartido
    └── Recursos/            Geist, Geist Mono, Instrument Serif y el grano
PruebasMando/                de punta a punta contra un TX-NR838, un Google TV y un Apple TV
                             falsos, y SRP contra valores calculados en Python
```

Cada protocolo (eISCP del Onkyo, y después el control remoto de Android TV y
el Companion del Apple TV) es un `Controlador`. La interfaz no cambia.

## La casa

- **Se guarda** en `Application Support/casa.json`: sólo la configuración; el
  estado en vivo (volumen, encendido) se vuelve a leer de cada aparato.
- **Migración:** la primera vez sin `casa.json`, si el Llavero tiene llaves de
  la versión anterior (cuentas «AppleTV» y «LG»), se arma la casa de
  esa versión con esas cuentas y el certificado «Mando» del Google TV, para no volver a
  emparejar nada. Sin llaves, la casa empieza vacía y la app ofrece buscar.
- **Cada aparato recuerda dónde contestó** (`host`, `puerto`); si deja de
  contestar ahí, el controlador vuelve a buscar una vez.
- **Al volver a la app** cada controlador revisa su conexión y reconecta si
  iOS la cortó; dos intentos a la vez esperan uno al otro.

## El Onkyo

- **Para que aparezca:** el receptor necesita red (cable o Wi-Fi) y **Network
  Standby** activado en Setup › Hardware › Power Management. Sin eso, apagado
  no contesta y la app no lo puede prender.
- **Búsqueda:** barre la subred (hasta 1024 direcciones, 64 a la vez) probando
  el puerto 60128. Tarda unos segundos la primera vez.
- **Entradas del TX-NR838:** las HDMI se llaman por lo que suele ir conectado
  (STRM BOX, BD/DVD, CBL/SAT, GAME…). En la casa de muestra
  (`Catalogo.casaAnterior()`) el Google TV va en CBL/SAT del Onkyo y el Apple
  TV, en otro cuarto y sin receptor.
- **Por confirmar con el receptor prendido:** que el volumen vaya de 1 en 1
  (si el receptor está en pasos de 0.5, `MVL` llega al doble) y los códigos
  de los modos de sonido.

## El Google TV

- **Emparejar:** la primera vez la tarjeta «Emparejar» abre seis casillas; la
  tele muestra el código. Los dos primeros caracteres son un dígito
  verificador, así que un código mal escrito se detecta antes de mandarlo.
- **Certificado:** el teléfono se presenta con un certificado propio que se
  crea una vez y vive en el Llavero (`Certificado.swift`, armado a mano en DER
  porque iOS no trae cómo crear uno). Si se borra la app, hay que volver a
  emparejar.
- **Volumen:** si el Google TV está conectado a una entrada del Onkyo
  (`volumenEn` en su configuración), sus teclas de volumen mueven el receptor.
- **Escribir:** la tele avisa cuando abre un campo de texto y manda dos
  contadores; la app los repite y manda el texto completo cada vez. Si no hay
  campo abierto, la hoja del teclado lo dice.
- **Encendido y silencio:** Android sólo tiene «alternar». La app recuerda lo
  que reportó la tele para no apagarla cuando se pidió prenderla.
- **Por confirmar con la tele prendida:** los enlaces que abren cada app y los
  nombres de paquete con que la tele reporta la app al frente
  (`AndroidTV.enlaces` y `AndroidTV.nombresDePaquete`).

## El Apple TV

Probado con un Apple TV HD (AppleTV5,3); anuncia Companion en el puerto
49153, pero el puerto se lee del anuncio de Bonjour.

- **Emparejar:** la tarjeta abre cuatro casillas numéricas; el Apple TV
  muestra el PIN. Por dentro es el alta de HomeKit: SRP-6a de 3072 bits con
  SHA-512 (la aritmética grande está escrita a mano en `EnteroGrande.swift`,
  con Montgomery), Ed25519 para las llaves de largo plazo y X25519 +
  ChaCha20-Poly1305 para cada sesión. Las credenciales viven en el Llavero.
- **Verificación:** en cada conexión los dos lados firman. Si alguien quitó a
  Mando en Ajustes › Controles remotos del Apple TV, la app borra sus
  credenciales y vuelve a pedir emparejar.
- **SRP comprobado por fuera:** `PruebasSRP` compara contra valores calculados
  con los enteros de Python; si la aritmética fallara, el Apple TV real
  rechazaría el PIN sin decir por qué.
- **Por confirmar con la tele:** que acepte la información con la que Mando se
  presenta al emparejar (`ControladorAppleTV.info`) y los identificadores de
  las apps (`ControladorAppleTV.apps`).

## Lo que se está viendo (Apple TV)

Como en la pantalla de bloqueo del iPhone: portada, título, serie con
temporada y episodio, y una barra que avanza sola. Viaja por AirPlay 2 (el
Media Remote Protocol dentro de su canal de datos), no por Companion.

- **Sin segundo PIN:** el Apple TV con que se probó acepta en AirPlay las mismas
  llaves de Companion. Si un día no, la app prueba las de AirPlay y, si
  tampoco, ofrece «Ver lo que se reproduce · Emparejar» con su propio PIN.
- **Tres conexiones cifradas**, cada una con sus llaves derivadas de la
  verificación: control (RTSP, con latido cada 2 s), avisos (la tele pregunta
  y se le contesta 200) y datos (MRP). Valores tomados de pyatv
  (`protocols/airplay/ap2_session.py`, `channels.py`, `mrp/protobuf`).
- **Lo que costó con la tele real:** el Apple TV avisa qué reproductor usa
  cada app (Música, Búsqueda…), y eso no quiere decir que esté al frente; y la
  respuesta con la portada trae el elemento sin metadatos, así que se juntan
  en vez de reemplazarse. Las dos cosas tienen su prueba (`secuenciaRealConDisney`).
- **Encendido:** el Apple TV no siempre dice si está prendido; si algo se está
  reproduciendo, la app lo da por prendido.

## La tele LG

Pensada para una LG con un Apple TV conectado: el control del Apple TV sube el
volumen de la LG por infrarrojo, así que el Apple TV no puede moverlo por la
red y la app le habla directo a la LG.

- **Encontrarla:** barre la subred buscando los puertos 3000 y 3001 abiertos a
  la vez (sólo uno podría ser una Mac con un servidor de desarrollo).
- **Permiso:** la primera vez la LG pregunta en pantalla; la app dice «Acepta
  en la tele» y se actualiza sola al aceptar. La llave queda en el Llavero.
- **Permisos sin firma:** se mandan sólo `CONTROL_AUDIO`, `CONTROL_POWER`,
  `READ_POWER_STATE` y `CONTROL_INPUT_MEDIA_PLAYBACK`, sin la firma larga que
  usan otras apps. Se comprobó con la LG real antes de escribir el controlador.

## La marca en la app

Tema Carbón: carbón `#121214`, tarjetas `#191919`
con hilo `#262626` y sin sombras, texto hueso `#F1EEE8`, retícula con cruces y
marcas de regla. Geist para leer, Geist Mono para lo que se mide e Instrument
Serif itálica en verde sólo para la palabra acento del título («Viendo
*Infuse*»).

Decisiones propias de la app:
- **Verde, sólo como señal.** El punto del kicker, la palabra acento, el punto
  que sigue al dedo en la superficie, el anillo del OK al apretar y el punto de
  la regla de volumen. Encendido se marca con relleno hueso, no con verde.
- **Gris de texto `#9C9A96`**, un punto más claro que el de la marca original,
  porque sobre el grano aquél se lee peor. Contraste: 6.3:1 sobre
  tarjeta, 6.7:1 sobre carbón.
- **Las teclas no se mueven.** El título es de una línea y mide lo mismo
  apagado o encendido, y la superficie y la cruceta comparten proporción, así
  que el pulgar encuentra todo en el mismo lugar en cualquier aparato.
- **Cambiar de aparato es instantáneo**, sin animación.
- El iPad usa la misma columna, de 460 pt de ancho: un control no se estira.

## Correr y probar

```bash
xcodegen && xcodebuild -project Mando.xcodeproj -scheme Mando -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build build
```

```bash
xcodebuild -project Mando.xcodeproj -scheme Mando -destination 'platform=iOS Simulator,name=iPhone 18 Pro' -derivedDataPath build test
```

Para compilarlo con tu cuenta de desarrollador cambia `DEVELOPMENT_TEAM` y
`bundleIdPrefix` en `project.yml`.

## Licencia

MIT. Ver [LICENSE](LICENSE). Las fuentes Geist, Geist Mono e Instrument Serif
van con su propia licencia, la SIL Open Font License (`Mando/Recursos/Fuentes/OFL.txt`).
