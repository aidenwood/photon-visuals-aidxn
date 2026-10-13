#ifndef PHOTON_FFI_H
#define PHOTON_FFI_H
#include <stdint.h>
#include <stdbool.h>

typedef struct { uint32_t id; int32_t blend; float opacity;
                 int32_t tex_slot; float position; uint32_t active; } PhotonLayer;

typedef struct { const PhotonLayer *layers; uint32_t layer_count;
                 double beat; float phase; float bpm; uint64_t frame_index; } PhotonFrame;

typedef struct PhotonCore PhotonCore;

PhotonCore *photon_create(float bpm);
void        photon_destroy(PhotonCore *h);
void        photon_set_layers(PhotonCore *h, const PhotonLayer *l, uint32_t n);
PhotonFrame photon_tick(PhotonCore *h, uint64_t dt_nanos);
void        photon_set_bpm(PhotonCore *h, float bpm);
/* Document. The .photon schema lives in Rust; the shell handles opaque JSON,
   so a Swift mirror can never drift from the Rust definition. Free every
   returned string with photon_string_free. */
typedef struct { char *ptr; uint32_t len; uint32_t ok; } PhotonString;

PhotonString photon_document_default(void);
PhotonString photon_document_validate(const char *json);
PhotonString photon_document_normalise(const char *json);
void         photon_string_free(PhotonString s);

void        photon_set_beat_lfo(PhotonCore *h, bool enabled, float beats);

/* Control mapping and learn mode.

   Crosses as packed structs rather than JSON on purpose: a JSON outcome would
   need a Swift type to decode into, and that type would be a SECOND definition
   of the mapping schema, free to drift from the Rust one. Saving the map IS
   JSON, because there the schema is the file format.

   Discriminants below are ABI. They mirror photon_ffi::{source_kind,
   value_kind, action_kind, routed_kind, ignored_reason}. */

enum { PHOTON_SOURCE_MIDI_CC = 0, PHOTON_SOURCE_MIDI_NOTE = 1,
       PHOTON_SOURCE_MIDI_PITCH_BEND = 2, PHOTON_SOURCE_OSC = 3,
       PHOTON_SOURCE_KEY = 4 };

enum { PHOTON_VALUE_MIDI7 = 0, PHOTON_VALUE_MIDI14 = 1,
       PHOTON_VALUE_UNIT = 2, PHOTON_VALUE_GATE = 3 };

enum { PHOTON_ACTION_TRIGGER_CELL = 0, PHOTON_ACTION_TRIGGER_COLUMN = 1,
       PHOTON_ACTION_CLEAR_LAYER = 2, PHOTON_ACTION_CUE_GO = 3,
       PHOTON_ACTION_BLACKOUT = 4, PHOTON_ACTION_TAP_TEMPO = 5,
       PHOTON_ACTION_RESYNC = 6 };

enum { PHOTON_ROUTED_IGNORED = 0, PHOTON_ROUTED_PARAMETER = 1,
       PHOTON_ROUTED_ACTION = 2, PHOTON_ROUTED_LEARNING = 3,
       PHOTON_ROUTED_LEARNED = 4 };

enum { PHOTON_IGNORED_UNBOUND = 0, PHOTON_IGNORED_RELEASE = 1,
       PHOTON_IGNORED_AWAITING_PICKUP = 2 };

typedef struct { int32_t kind; uint8_t channel; uint8_t number;
                 const char *text; } PhotonControlSource;

/* `path` and `displaced_label` are owned by the core and valid only until the
   next control call on the same handle — the same rule as PhotonFrame. */
typedef struct { int32_t kind; int32_t ignored; float position;
                 int32_t action; uint32_t a; uint32_t b;
                 const char *path; uint32_t displaced;
                 const char *displaced_label; } PhotonRouted;

bool         photon_control_arm_parameter(PhotonCore *h, const char *path);
bool         photon_control_arm_action(PhotonCore *h, int32_t action, uint32_t a, uint32_t b);
void         photon_control_disarm(PhotonCore *h);
bool         photon_control_is_learning(const PhotonCore *h);
/* current_position: the parameter's present 0-1 position, or NEGATIVE for
   unknown. Pickup compares against it; a value nothing knows cannot jump. */
PhotonRouted photon_control_event(PhotonCore *h, PhotonControlSource source,
                                  int32_t value_kind, float value,
                                  float current_position);
PhotonString photon_control_map(const PhotonCore *h);
PhotonString photon_control_map_load(PhotonCore *h, const char *json);
bool         photon_control_unbind(PhotonCore *h, PhotonControlSource source);
void         photon_control_reset_pickup(PhotonCore *h);
/* The parameter path a source is bound to, or NULL. Owned by the core, valid
   until the next control call. Exists so pickup can ask for the target's
   current value without serialising the whole map per event. */
const char  *photon_control_bound_path(PhotonCore *h, PhotonControlSource source);
uint32_t     photon_control_binding_count(const PhotonCore *h);

/* Audio reactivity.

   The CORE decides which frequency bands exist — they come from whatever is
   bound — so the shell asks for the list, computes exactly those, and pushes
   the values back. It pushes RAW band energy, not an envelope: attack and
   release live with the binding, in the core, so they are shared with the
   Windows shell and applied exactly once. Smoothing on both sides is not twice
   as smooth, it is laggy, and it gets blamed on the audio interface. */

bool        photon_bind_audio(PhotonCore *h, const char *param_path,
                              float low_hz, float high_hz,
                              float attack_ms, float release_ms,
                              float depth, bool invert);
bool        photon_unbind_audio(PhotonCore *h, const char *param_path);
uint32_t    photon_audio_band_count(const PhotonCore *h);
bool        photon_audio_band(const PhotonCore *h, uint32_t index,
                              float *low_hz, float *high_hz);
bool        photon_set_audio_band(PhotonCore *h, uint32_t index, float value);

/* DXV decode.

   The shell demuxes (AVFoundation here, libavformat on Windows) and hands in
   one compressed DXV frame. The core undoes the LZ layer and hands back BC1 or
   BC3 BLOCKS — never pixels. The frames being already GPU block-compressed is
   the whole reason DXV is cheap to play; expanding to RGBA, which is what
   FFmpeg's own DXV decoder does, throws that away.

   `data` is owned by the decoder and valid only until the next decode on the
   same decoder — the same rule as PhotonFrame.

   One decoder per layer: DXV has no chunk table, so a frame is a single
   contiguous LZ stream that cannot be split across workers. */

typedef struct PhotonDxvDecoder PhotonDxvDecoder;

enum { PHOTON_DXV_OK = 0, PHOTON_DXV_NULL_ARG = 1, PHOTON_DXV_TRUNCATED = 2,
       PHOTON_DXV_MALFORMED = 3, PHOTON_DXV_UNKNOWN_FORMAT = 4,
       PHOTON_DXV_UNKNOWN_COMPRESSOR = 5, PHOTON_DXV_BAD_DISTANCE = 6,
       /* YCG6 / YG10. Returned rather than guessed: plausible-looking wrong
          pixels in a live show are worse than a clip that refuses to load. */
       PHOTON_DXV_NOT_DERIVED = 7 };

enum { PHOTON_TEX_BC1_RGB = 0, PHOTON_TEX_BC3_RGBA = 1, PHOTON_TEX_BC3_YCOCG = 2,
       PHOTON_TEX_BC4_ALPHA = 3, PHOTON_TEX_BC6H_UNSIGNED = 4,
       PHOTON_TEX_BC6H_SIGNED = 5, PHOTON_TEX_BC7_RGBA = 6 };

/* texture_width/height are PADDED (width aligns to 16, height to 4); the
   visible frame is the top-left crop, so a sampler must scale by
   width/texture_width.

   premultiplied != 0 means the RGB in the blocks is multiplied by alpha and the
   SAMPLER must divide it back out: out = min(1, c / a), passing c through when
   a == 0. True for DXV's DXT5. Skip it and every real Resolume DXT5 asset
   renders visibly dark. */
typedef struct { const uint8_t *data; uint32_t len; int32_t format;
                 uint32_t texture_width; uint32_t texture_height;
                 uint32_t premultiplied; int32_t status; } PhotonDxvFrame;

PhotonDxvDecoder *photon_dxv_decoder_create(void);
void              photon_dxv_decoder_destroy(PhotonDxvDecoder *d);
PhotonDxvFrame    photon_dxv_decode(PhotonDxvDecoder *d, const uint8_t *frame,
                                    uint32_t len, uint32_t width, uint32_t height);
/* Owned by the decoder, valid until the next decode. Never NULL; empty means
   nothing to report. */
const char       *photon_dxv_last_error(const PhotonDxvDecoder *d);
uint32_t          photon_dxv_frame_stride(void);

uint32_t    photon_abi_version(void);
uint32_t    photon_layer_stride(void);
uint32_t    photon_frame_stride(void);
uint32_t    photon_routed_stride(void);
uint32_t    photon_control_source_stride(void);
#endif
