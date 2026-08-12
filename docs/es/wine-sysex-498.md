# Wine descarta en silencio todo sysex de más de 498 bytes

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

Una **DLL proxy de `winmm`** delante de la de Wine: reenvía sus 186 exports intactos e intercepta sólo `midiOutOpen`, `midiOutClose` y `midiOutLongMsg`.

Lo que baja de 498 bytes pasa sin tocarlo. Lo más largo se trocea en bloques de 400 con 160 ms de pausa (≈2500 B/s, por debajo de los 3125 del cable DIN, lo que de paso evita desbordar la interfaz). Ajustable con `WINMM_CHUNK`, `WINMM_DELAY` y `WINMM_LOG`.

### Cómo funciona por dentro

**La cabecera de la aplicación no se toca nunca.** Los trozos se envían con otra:

| Tipo de callback | Dónde vive la cabecera de troceo |
|---|---|
| `CALLBACK_FUNCTION`, `CALLBACK_NULL` | en la pila — los avisos se filtran y se atienden dentro de la propia llamada |
| `CALLBACK_WINDOW`, `_THREAD`, `_EVENT` | en el montón — el driver *publica* mensajes que la aplicación lee después, así que tiene que sobrevivir a la llamada |

Las del montón van a un **anillo acotado a 16 por handle**, liberado al cerrar. No se pueden liberar antes porque puede quedar un mensaje encolado apuntando a ellas.

**Los envíos de un handle están serializados** por una sección crítica propia. `midiOutClose` espera a que termine el envío en curso antes de liberar nada.

**Los avisos se filtran por puntero:** `midiOutOpen` sustituye el callback cuando es `CALLBACK_FUNCTION`, y sólo se traga el `MOM_DONE` cuya cabecera es exactamente la del trozo en vuelo. Al terminar se emite un único aviso con la cabecera de la aplicación intacta, y **sólo si el envío tuvo éxito**.

### Limitación conocida, y no es inofensiva

Con `CALLBACK_WINDOW`, `CALLBACK_EVENT` o `CALLBACK_THREAD` no hay forma de filtrar los avisos del driver desde fuera: la aplicación recibe uno por trozo. Llevan *nuestra* cabecera en vez de la suya, pero eso **no la pone a salvo** — su `lpData` apunta a mitad del búfer de la aplicación, así que el manejador corriente (`unprepare` y `free(lpData)`) liberaría un puntero interior igualmente.

**Con esos tipos de callback el proxy no es seguro para volcados largos.** Se envían igual porque sin él no sale nada, pero si tu aplicación usa callback de ventana y hace limpieza en el aviso de fin, no uses esto todavía.

### Cuatro cosas que costaron encontrar

1. **No se puede abrir un segundo handle al mismo dispositivo.** Wine devuelve `MMSYSERR_ALLOCATED`, así que la idea evidente —mandar los trozos por un handle privado— no es viable.
2. **Wine atiende `MOM_DONE` de forma síncrona dentro de `midiOutLongMsg`.** Por eso mutar la cabecera de la aplicación era corrupción de memoria: el aviso del último trozo le llegaba apuntando a mitad del bloque.
3. **Wine emite `MOM_OPEN` durante la propia llamada a `midiOutOpen`.** La entrada de la tabla de handles hay que reservarla y rellenarla **entera antes** de abrir, y limpiarla entera al cerrar.
4. **Un solo indicador de seguimiento por handle no basta.** Con dos envíos simultáneos el segundo pisa al primero y los avisos del perdedor llegan a la aplicación apuntando a mitad de su búfer. De ahí la serialización.

### Estado de la verificación

Medido de extremo a extremo, desde dentro de la botella hacia un puerto de captura: **498, 499, 15.549 y 18.749 bytes llegan como un único sysex del tamaño exacto**.

Lo que **no** está verificado, dicho para que nadie se confíe:

- El camino de `CALLBACK_WINDOW`/`_THREAD`/`_EVENT` no se ha probado con una aplicación real, sólo razonado. Ver la limitación de arriba.
- El comportamiento con varios hilos enviando a la vez está resuelto por diseño (serialización), no demostrado con una prueba.
- Las herramientas Swift y los scripts han pasado compilación y `sh -n`, pero la revisión sistemática de esa parte quedó incompleta.

El código ha pasado cuatro rondas de revisión adversaria, con 11, 2, 9 y 13 defectos encontrados. Varias rondas introdujeron defectos nuevos al arreglar los anteriores, casi todos en la parte de concurrencia. Trátalo en consecuencia.

## El arreglo correcto

En Wine, un bucle en `midi_send` que envíe en trozos de ≤498 bytes reinicializando la lista de paquetes en cada vuelta. Apple documenta explícitamente que un paquete puede contener **parte** de un sysex, así que trocear está sancionado por la API. Alternativamente, reservar el búfer del tamaño necesario, respetando el techo documentado de 65536 bytes por lista.

## Un segundo tope, independiente

**CoreMIDI trunca en 12001 bytes** cualquier sysex entregado en una sola llamada a `MIDISend`, también sin dar error. Ver [coremidi-12001.md](coremidi-12001.md). Por eso la solución tiene que trocear, no simplemente agrandar el búfer.
