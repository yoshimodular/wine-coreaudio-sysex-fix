# CoreMIDI trunca en 12001 bytes

> Documento original en castellano. Versión en inglés: [../coremidi-12001.md](../coremidi-12001.md)

Medido en macOS 15.7.3, Apple Silicon.

**Cualquier sysex entregado a CoreMIDI en una sola llamada a `MIDISend` se trunca en 12001 bytes.** `MIDISend` devuelve `noErr` y los bytes sobrantes desaparecen sin aviso.

## La medida

Barriendo tamaños hacia un destino virtual:

| Enviado | Recibido |
|---:|---:|
| 12.000 | 12.000 |
| 12.002 | 12.002 |
| 12.500 | **12.001** |
| 15.549 | **12.001** |

El mismo contenido troceado en bloques de 256 bytes con ~100 ms de pausa llega **idéntico byte a byte**.

No es culpa del emisor: `MIDIPacketListAdd` construye correctamente listas de hasta 40.000 bytes (comprobado en local). El corte está en el traspaso al `MIDIServer`.

## Consecuencias prácticas

**El troceado tiene que hacerlo la aplicación que envía.** No hay forma de arreglarlo desde fuera:

- **`kMIDIPropertyMaxSysExSpeed` no sirve.** Es la propiedad con la que CoreMIDI regula el ritmo del sysex, pero **sólo la respeta `MIDISendSysex`, no `MIDISend`** — y `MIDISend` es lo que usan Wine y la mayoría de aplicaciones. Comprobado fijándola a 3125 y midiendo: no frena nada. Los puertos de red (RTP-MIDI) ni siquiera la declaran.

- **Un puerto virtual intermedio tampoco vale**: su entrada sufre el mismo tope, así que recibe el mensaje ya truncado.

- **Un driver de CoreMIDI intermedio tampoco.** Se comprobó con el espía de MIDI Monitor ("Spy on output to destinations"), que observa desde dentro del `MIDIServer`: al mandar 15.549 bytes en una llamada, el espía reporta **12.001**. El corte ocurre antes de que ningún driver pueda verlo.

## Dos trampas al medir

Ambas producen datos falsos y cuestan horas:

**1. No copiar el `MIDIPacket` por valor.** El campo `data` es una tupla fija de 256 bytes; leer más devuelve basura de la pila, y `MIDIPacketNext` sobre la copia calcula mal la siguiente dirección:

```swift
// MAL
var p = pl.pointee.packet
// BIEN: punteros sobre la lista original
let pktOffset  = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!
var pkt = UnsafeMutableRawPointer(mutating: UnsafeRawPointer(pl))
    .advanced(by: pktOffset).assumingMemoryBound(to: MIDIPacket.self)
```

**2. El callback de recepción tiene que ser rapidísimo.** Si escribe a disco en cada paquete, CoreMIDI descarta lo que llega mientras tanto y uno acaba midiendo la lentitud de su propio instrumento, no el límite que buscaba.

## Y al enviar

Trocear en fragmentos **pequeños** tampoco vale: con bloques de una docena de bytes CoreMIDI destroza el mensaje a partir del primero. Con 256 bytes llega intacto. Ese es el tamaño que usan las herramientas de este repositorio.
