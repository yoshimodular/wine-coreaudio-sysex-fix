# Wine descarta en silencio todo sysex de más de 498 bytes

> Documento original en castellano. Versión en inglés: [../wine-sysex-498.md](../wine-sysex-498.md)

**Afecta a:** cualquier aplicación de Windows que envíe System Exclusive a un puerto MIDI real bajo Wine o CrossOver **en macOS**. En Linux no ocurre.

**Estado aguas arriba:** sin arreglar, desde 2015.

---

## El síntoma

Un editor MIDI transmite un volcado de banco. El programa informa de que ha ido bien. Al sintetizador no llega nada, o se queda esperando indefinidamente un mensaje que nunca se cierra.

Los mensajes cortos —editar un parámetro, cambiar de programa— funcionan perfectamente en ambos sentidos. Sólo fallan los volcados grandes.

## La causa

`dlls/winecoreaudio.drv/coremidi.c`, función `midi_send`:

```c
static void midi_send(MIDIPortRef port, MIDIEndpointRef dest, UInt8 *buffer, unsigned len)
{
    Byte packet_buf[512];
    MIDIPacketList *packet_list = (MIDIPacketList *)packet_buf;
    MIDIPacket *packet = MIDIPacketListInit(packet_list);

    packet = MIDIPacketListAdd(packet_list, sizeof(packet_buf), packet,
                               mach_absolute_time(), len, buffer);
    if (packet) MIDISend(port, dest, packet_list);
}
```

Un búfer fijo de 512 bytes y **una sola** llamada a `MIDIPacketListAdd`, con el mensaje entero. Si no cabe, la función devuelve `NULL` —comportamiento documentado por Apple— y el `if` se salta el envío.

Y quien la llama, `midi_out_long_data` (el manejador de `MODM_LONGDATA`), no trocea:

```c
else if (dest->caps.wTechnology == MOD_MIDIPORT)
    midi_send(midi_out_port, dest->dest, (UInt8 *)hdr->lpData, hdr->dwBufferLength);

hdr->dwFlags &= ~MHDR_INQUEUE;
hdr->dwFlags |= MHDR_DONE;
set_out_notify(notify, dest, dev_id, MOM_DONE, (UINT_PTR)hdr, 0);
return MMSYSERR_NOERROR;
```

Marca la cabecera como completada, notifica `MOM_DONE` y devuelve **éxito**. La aplicación no tiene forma de enterarse.

Sólo afecta a la vía `MOD_MIDIPORT` (puertos MIDI reales). La vía `MOD_SYNTH` usa `MusicDeviceSysEx` con la longitud completa y no tiene el problema.

## El número exacto: 498 bytes

`MIDIServices.h` empaqueta ambas estructuras a 4 bytes, así que en arm64 y en x86_64 por igual:

```
offsetof(MIDIPacketList, packet) =  4
offsetof(MIDIPacket, data)       = 10
512 − 4 − 10                     = 498
```

Verificado reproduciendo la llamada con el mismo búfer y barriendo tamaños:

```
ultimo tamano que CABE : 498 bytes
primero que NO cabe    : 499 bytes
```

## Medido en vivo

Con `wmiditest.exe` (incluido) enviando por `midiOutLongMsg` desde dentro de la botella a un puerto virtual de captura:

| Enviado | Recibido | Devuelve |
|---:|---:|---|
| 498 bytes | **498** | `MMSYSERR_NOERROR` |
| 499 bytes | **0** | `MMSYSERR_NOERROR` |
| 15.549 bytes | **0** | `MMSYSERR_NOERROR` |

Un byte separa que funcione de que desaparezca sin rastro informando de éxito.

## Historia

- **2007** — commit `622ee1c4cc3b` introduce `MIDIOut_Send` con el búfer de 512 bytes, para mensajes cortos de 3 bytes, donde sobra.
- **Nov 2015** — commit `387fbdc7a164` ("winecoreaudio: Handle sysex MIDI messages", Wine 1.7.55) conecta el sysex a esa misma función. Añade troceado **en la entrada**, pero no en la salida.
- **Hoy** — sin cambios en `midi_send`.

El driver de ALSA (`dlls/winealsa.drv/alsamidi.c`) entrega el búfer entero al secuenciador y no tiene este límite. `winmm` tampoco capa ni trocea: pasa `MODM_LONGDATA` tal cual. Es un defecto específico del backend de CoreAudio.

## La solución de este repositorio

Una **DLL proxy de `winmm`** que se pone delante de la de Wine: reenvía sus 186 exports intactos y sólo intercepta `midiOutOpen`, `midiOutClose` y `midiOutLongMsg`. Lo que baja de 498 bytes pasa sin tocarlo; lo más largo se trocea en bloques de 400 con pausa entre ellos (≈2500 B/s, por debajo de los 3125 del cable DIN, lo que de paso evita desbordar la interfaz).

Detalles que costaron encontrar:

1. **No se puede abrir un segundo handle al mismo dispositivo** — Wine devuelve `MMSYSERR_ALLOCATED`. Así que el diseño evidente —un handle privado sobre el que trocear, sin tocar el de la aplicación— no está disponible: los trozos tienen que salir por el handle de la aplicación.

2. **La cabecera de la aplicación no se toca.** Los trozos se envían con una `MIDIHDR` propia. Reutilizar la suya, mutándole `lpData` y `dwBufferLength`, es peligroso: Wine atiende `MOM_DONE` de forma síncrona dentro de la llamada, así que el aviso del último trozo le llegaría apuntando a mitad del bloque, y un manejador normal (`unprepare` y `free(lpData)`) liberaría un puntero 15 KB dentro de la reserva.

3. Para que reciba **un solo** aviso de fin, `midiOutOpen` sustituye el callback cuando es `CALLBACK_FUNCTION`, se traga los de los trozos, y al terminar se emite uno con la cabecera intacta.

   **Limitación conocida:** con `CALLBACK_WINDOW`, `CALLBACK_EVENT` o `CALLBACK_THREAD` no hay forma de filtrar los avisos del driver desde fuera, así que la aplicación recibe uno por trozo. Van con *nuestra* cabecera, no con la suya —memoria válida y ajena, en vez de la suya corrompida—, y al final se le entrega el suyo con `PostMessage`/`SetEvent`. Si una aplicación de este tipo se comporta raro con volcados grandes, es aquí donde hay que mirar.

4. **Wine emite `MOM_OPEN` durante la propia llamada a `midiOutOpen`.** Si la entrada de la tabla de handles se rellena *después* de abrir, ese callback se ejecuta con datos a medias, o con el puntero del handle anterior si al cerrar sólo se borró el handle. Hay que reservar y rellenar la entrada **entera antes** de abrir, y limpiarla entera al cerrar.

## El arreglo correcto

En Wine, un bucle en `midi_send` que envíe en trozos de ≤498 bytes reinicializando la lista de paquetes en cada vuelta. Apple documenta explícitamente que un paquete puede contener **parte** de un sysex, así que trocear está sancionado por la API. Alternativamente, reservar el búfer del tamaño necesario, respetando el techo documentado de 65536 bytes por lista.

## Un segundo tope, independiente

**CoreMIDI trunca en 12001 bytes** cualquier sysex entregado en una sola llamada a `MIDISend`, también sin dar error. Ver [coremidi-12001.md](coremidi-12001.md). Por eso la solución tiene que trocear, no simplemente agrandar el búfer.
