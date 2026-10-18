// Keep Nintendo's vibration files, players and mixers in the original SDK;
// replace only calls that would otherwise reach the unavailable hid service.
#include "hle.h"
#include "dm_vibration.h"
uint32_t hle_hid_connected_npad(void);

HLE_FORCE("_ZN2nn3hid20IsVibrationPermittedEv", "tvOS vibration permission", unsigned, vib_permitted, void) { return dm_vibration_permitted(); }
HLE_FORCE("_ZN2nn3hid25GetVibrationDeviceHandlesEPNS0_21VibrationDeviceHandleEiRKjNS_4util10BitFlagSetILi32ENS0_12NpadStyleTagEEE", "tvOS left/right vibration handles", int, vib_handles, uint32_t *out, int n, const uint32_t *id, uint32_t style) {
    return *id == hle_hid_connected_npad() ? dm_vibration_handles(out, n, *id, style) : 0;
}
HLE_FORCE("_ZN2nn3hid25InitializeVibrationDeviceERKNS0_21VibrationDeviceHandleE", "tvOS driver owns device initialization", void, vib_init, const uint32_t *h) { (void)h; }
HLE_FORCE("_ZN2nn3hid18SendVibrationValueERKNS0_21VibrationDeviceHandleERKNS0_14VibrationValueE", "tvOS HD vibration value", void, vib_send, const uint32_t *h, const dm_vibration_value *v) { dm_vibration_send(h, v, 1); }
HLE_FORCE("_ZN2nn3hid22GetVibrationDeviceInfoEPNS0_19VibrationDeviceInfoERKNS0_21VibrationDeviceHandleE", "tvOS LRA device position", void, vib_info, uint32_t *out, const uint32_t *h) { dm_vibration_info(*h, out); }
HLE_FORCE("_ZN2nn3hid23GetActualVibrationValueEPNS0_14VibrationValueERKNS0_21VibrationDeviceHandleE", "tvOS accepted vibration state", void, vib_actual, dm_vibration_value *out, const uint32_t *h) { dm_vibration_actual(*h, out); }
HLE_FORCE("_ZN2nn3hid24IsVibrationDeviceMountedERKNS0_21VibrationDeviceHandleE", "tvOS haptic actuator connection", unsigned, vib_mounted, const uint32_t *h) { return dm_vibration_mounted(*h); }
HLE_FORCE("_ZN2nn3hid27BeginForcedVibrationSessionEv", "tvOS forced vibration session", void, vib_force_begin, void) { dm_vibration_force(1); }
HLE_FORCE("_ZN2nn3hid25EndForcedVibrationSessionEv", "tvOS forced vibration session end", void, vib_force_end, void) { dm_vibration_force(0); }

HLE_FORCE("_ZN2nn3hid6detail15PermitVibrationEb", "replace hid permission service", Result, vib_detail_permit, unsigned on) { dm_vibration_permit(on); return RES_OK; }
HLE_FORCE("_ZN2nn3hid6detail20IsVibrationPermittedEPb", "replace hid permission query", Result, vib_detail_permitted, uint8_t *out) { *out = dm_vibration_permitted(); return RES_OK; }
HLE_FORCE("_ZN2nn3hid6detail27BeginPermitVibrationSessionEv", "replace hid forced session service", Result, vib_detail_begin, void) { dm_vibration_force(1); return RES_OK; }
HLE_FORCE("_ZN2nn3hid6detail25EndPermitVibrationSessionEv", "replace hid forced session end", Result, vib_detail_end, void) { dm_vibration_force(0); return RES_OK; }
HLE_FORCE("_ZN2nn3hid6detail25InitializeVibrationDeviceERKNS0_21VibrationDeviceHandleE", "tvOS driver owns device initialization", Result, vib_detail_init, const uint32_t *h) { (void)h; return RES_OK; }
HLE_FORCE("_ZN2nn3hid6detail22GetVibrationDeviceInfoEPNS0_19VibrationDeviceInfoERKNS0_21VibrationDeviceHandleE", "replace hid actuator information", Result, vib_detail_info, uint32_t *out, const uint32_t *h) { dm_vibration_info(*h, out); return RES_OK; }
HLE_FORCE("_ZN2nn3hid6detail18SendVibrationValueERKNS0_21VibrationDeviceHandleERKNS0_14VibrationValueE", "replace hid single vibration submission", Result, vib_detail_send, const uint32_t *h, const dm_vibration_value *v) { dm_vibration_send(h, v, 1); return RES_OK; }
HLE_FORCE("_ZN2nn3hid6detail19SendVibrationValuesEPKNS0_21VibrationDeviceHandleEPKNS0_14VibrationValueEi", "replace SDK graph batch flush into hid", Result, vib_detail_batch, const uint32_t *h, const dm_vibration_value *v, int count) { dm_vibration_send(h, v, count); return RES_OK; }
HLE_FORCE("_ZN2nn3hid6detail23GetActualVibrationValueEPNS0_14VibrationValueERKNS0_21VibrationDeviceHandleE", "replace hid current vibration query", Result, vib_detail_actual, dm_vibration_value *out, const uint32_t *h) { dm_vibration_actual(*h, out); return RES_OK; }
HLE_FORCE("_ZN2nn3hid6detail24IsVibrationDeviceMountedEPbRKNS0_21VibrationDeviceHandleE", "replace hid actuator connection query", Result, vib_detail_mounted, uint8_t *out, const uint32_t *h) { *out = dm_vibration_mounted(*h); return RES_OK; }
