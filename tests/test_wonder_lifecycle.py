"""Small native regression checks; synthetic values only, no game data.

Run after operational validation:
  python3 -m unittest discover -s tests -p test_wonder_lifecycle.py -v

The vibration checks need a C compiler (NS2APP_TEST_CC, e.g. 'zig cc').
The AudioUnit and Core Haptics fault harnesses additionally need macOS and its
SDK; no sound device or controller is opened. NS2APP_TEST_CFLAGS adds flags.
"""
import ctypes as C
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / 'nxnative/dm/host'


def compiler():
    command = shlex.split(os.environ.get('NS2APP_TEST_CC', os.environ.get('CC', 'cc')))
    if not command or not shutil.which(command[0]):
        raise unittest.SkipTest('C compiler unavailable; set NS2APP_TEST_CC')
    return command + shlex.split(os.environ.get('NS2APP_TEST_CFLAGS', ''))


def run_checked(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'Command failed ({result.returncode}): {shlex.join(command)}\n'
                           + result.stdout + result.stderr)
    return result


class Value(C.Structure):
    _fields_ = [(name, C.c_float) for name in
                ('low_amplitude', 'low_frequency', 'high_amplitude', 'high_frequency')]


class Frame(C.Structure):
    _fields_ = [('value', Value * 2), ('generation', C.c_uint64), ('submitted_ns', C.c_uint64)]


LEFT, RIGHT = 3, 3 | (1 << 16)
SILENCE = (0, 160, 0, 320)


class VibrationLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(temporary.cleanup)
        library = Path(temporary.name) / 'vibration.so'
        run_checked(compiler() + ['-std=c11', '-D_POSIX_C_SOURCE=200809L', '-shared', '-fPIC',
                    '-I', str(HOST), str(ROOT / 'tests/native/wonder_vibration_clock.c'),
                    '-o', str(library), '-pthread', '-lm'])
        cls.lib = C.CDLL(str(library))
        signatures = {
            'handles': ([C.POINTER(C.c_uint32), C.c_int, C.c_uint32, C.c_uint32], C.c_int),
            'side': ([C.c_uint32], C.c_int),
            'info': ([C.c_uint32, C.POINTER(C.c_uint32)], None),
            'mounted': ([C.c_uint32], C.c_int),
            'set_available': ([C.c_uint], None), 'set_active': ([C.c_int], None),
            'controller_begin': ([], C.c_uint64),
            'controller_mount': ([C.c_uint, C.c_uint64], None),
            'permit': ([C.c_int], None), 'force': ([C.c_int], None),
            'permitted': ([], C.c_int), 'generation': ([], C.c_uint64),
            'send': ([C.POINTER(C.c_uint32), C.POINTER(Value), C.c_int], None),
            'actual': ([C.c_uint32, C.POINTER(Value)], None),
            'snapshot': ([C.POINTER(Frame)], None), 'take': ([C.POINTER(Frame)], C.c_int),
            'sharpness': ([C.c_float], C.c_float),
        }
        for name, (args, result) in signatures.items():
            function = getattr(cls.lib, 'dm_vibration_' + name)
            function.argtypes, function.restype = args, result
        cls.lib.test_advance_ns.argtypes = [C.c_uint64]
        cls.lib.test_advance_ns.restype = None

    def setUp(self):
        self.lib.dm_vibration_set_active(0)
        self.lib.dm_vibration_set_available(0)
        self.lib.dm_vibration_permit(1)
        self.lib.dm_vibration_force(0)
        self.lib.dm_vibration_set_available(3)
        self.lib.dm_vibration_set_active(1)
        self.drain()

    def drain(self):
        result = []
        frame = Frame()
        while self.lib.dm_vibration_take(C.byref(frame)):
            result.append(Frame.from_buffer_copy(frame))
        return result

    def send(self, *pairs):
        handles = (C.c_uint32 * len(pairs))(*(p[0] for p in pairs))
        values = (Value * len(pairs))(*(Value(*p[1]) for p in pairs))
        self.lib.dm_vibration_send(handles, values, len(pairs))

    def assertValue(self, actual, expected):
        for (name, _), value in zip(Value._fields_, expected):
            self.assertAlmostEqual(getattr(actual, name), value, places=4, msg=name)

    def assertSilent(self):
        for handle in (LEFT, RIGHT):
            value = Value()
            self.lib.dm_vibration_actual(handle, C.byref(value))
            self.assertValue(value, SILENCE)

    def test_handles_preserve_nintendo_style_id_and_left_right_positions(self):
        for npad, style, expected in [(0, 1, [3, 0x10003]), (0, 4, [5, 0x10005]),
                                     (0, 8, [6]), (0, 16, [0x10007]),
                                     (0x20, 2, [0x2004, 0x12004]), (1, 1, []), (0, 2, [])]:
            with self.subTest(npad=npad, style=style):
                out = (C.c_uint32 * 3)(0xdeadbeef, 0xdeadbeef, 0xdeadbeef)
                count = self.lib.dm_vibration_handles(out, 2, npad, style)
                self.assertEqual(list(out)[:count], expected)
                self.assertEqual(out[count], 0xdeadbeef)
                for handle in expected:
                    side = (handle >> 16) & 255
                    info = (C.c_uint32 * 2)()
                    self.lib.dm_vibration_info(handle, info)
                    self.assertEqual(list(info), [1, side + 1])
                    self.assertEqual(self.lib.dm_vibration_side(handle), side)
        for handle in (0, 4, 0x10006, 7, 0x20003, 0x1000003, 0x103, 0x2003):
            self.assertEqual(self.lib.dm_vibration_side(handle), -1)
            self.assertEqual(self.lib.dm_vibration_mounted(handle), 0)

    def test_batch_and_single_updates_keep_all_four_envelopes_and_explicit_stop(self):
        left, right = (0.25, 80, 0.75, 400), (0.6, 200, 0.4, 700)
        self.send((LEFT, left), (RIGHT, right))
        first = self.drain()
        self.assertEqual(len(first), 1)
        self.assertValue(first[0].value[0], left)
        self.assertValue(first[0].value[1], right)
        self.send((RIGHT, right))
        self.assertEqual(self.drain(), [])
        self.send((LEFT, SILENCE))
        stopped = self.drain()
        self.assertEqual(len(stopped), 1)
        self.assertValue(stopped[0].value[0], SILENCE)
        self.assertValue(stopped[0].value[1], right)
        self.lib.test_advance_ns(60_000_000_000)
        value = Value()
        self.lib.dm_vibration_actual(RIGHT, C.byref(value))
        self.assertValue(value, right)  # Sustains do not expire without a game stop.

    def test_focus_disconnect_and_permission_invalidate_queued_effects(self):
        effect = (0.8, 160, 0.9, 320)
        for change in (lambda: self.lib.dm_vibration_set_active(0),
                       lambda: self.lib.dm_vibration_set_available(0),
                       lambda: self.lib.dm_vibration_permit(0)):
            self.setUp()
            self.send((LEFT, effect), (RIGHT, effect))
            before = self.lib.dm_vibration_generation()
            change()
            self.send((LEFT, effect))
            self.assertGreater(self.lib.dm_vibration_generation(), before)
            frames = self.drain()
            self.assertEqual(len(frames), 1)
            for value in frames[0].value:
                self.assertValue(value, SILENCE)
            self.assertSilent()
            self.lib.dm_vibration_set_active(1)
            self.lib.dm_vibration_set_available(3)
            self.lib.dm_vibration_permit(1)
            self.assertSilent()  # Reconnect/resume cannot replay the old effect.
        self.lib.dm_vibration_permit(0)
        self.lib.dm_vibration_force(1)
        self.assertEqual(self.lib.dm_vibration_permitted(), 1)
        self.send((LEFT, effect))
        actual = Value()
        self.lib.dm_vibration_actual(LEFT, C.byref(actual))
        self.assertValue(actual, effect)
        self.lib.dm_vibration_force(0)
        self.assertEqual(self.lib.dm_vibration_permitted(), 0)
        self.assertSilent()

    def test_stalled_driver_discards_impacts_but_delivers_latest_sustain_or_stop(self):
        for final in ((0.6, 180, 0.4, 600), SILENCE):
            with self.subTest(final=final):
                for index in range(600):
                    self.send((LEFT, (0.8, 80 + index % 400, 0.9, 320)))
                self.send((LEFT, final))
                self.lib.test_advance_ns(101_000_000)
                frames = self.drain()
                self.assertEqual(len(frames), 1)
                self.assertValue(frames[0].value[0], final)
        self.send((LEFT, (0.5, 160, 0.5, 320)))
        self.lib.test_advance_ns(101_000_000)
        recent = (0.2, 90, 0.7, 500)
        self.send((LEFT, recent))
        self.send((LEFT, SILENCE))
        frames = self.drain()
        self.assertEqual(len(frames), 2)
        self.assertValue(frames[0].value[0], recent)
        self.assertValue(frames[1].value[0], SILENCE)

    def test_obsolete_controller_setup_cannot_undo_disconnect_or_new_selection(self):
        self.send((LEFT, (0.8, 160, 0.9, 320)))
        old = self.lib.dm_vibration_controller_begin()
        latest = self.lib.dm_vibration_controller_begin()
        self.lib.dm_vibration_controller_mount(0, latest)
        self.lib.dm_vibration_controller_mount(3, old)
        self.assertEqual(self.lib.dm_vibration_mounted(LEFT), 0)
        self.assertEqual(self.lib.dm_vibration_mounted(RIGHT), 0)
        self.assertSilent()
        current = self.lib.dm_vibration_controller_begin()
        self.lib.dm_vibration_set_active(0)
        self.lib.dm_vibration_set_active(1)
        self.lib.dm_vibration_controller_mount(2, current)
        self.lib.dm_vibration_controller_mount(3, latest)
        self.assertEqual(self.lib.dm_vibration_mounted(LEFT), 0)
        self.assertEqual(self.lib.dm_vibration_mounted(RIGHT), 1)
        self.assertSilent()

    def test_nonfinite_and_out_of_range_values_cannot_reach_haptic_driver(self):
        self.send((LEFT, (float('nan'), float('inf'), 4, -1)),
                  (RIGHT, (-3, 1, float('inf'), 10000)))
        frame, = self.drain()
        self.assertValue(frame.value[0], (0, 160, 1, 320))
        self.assertValue(frame.value[1], (0, 40.875, 0, 1252.572))
        mapped = [self.lib.dm_vibration_sharpness(f) for f in (40.875, 160, 320, 1252.572)]
        self.assertEqual(mapped[0], 0)
        self.assertEqual(mapped[-1], 1)
        self.assertEqual(mapped, sorted(mapped))
        for frequency in (float('nan'), float('inf'), -1, 0):
            self.assertEqual(self.lib.dm_vibration_sharpness(frequency), 0)


@unittest.skipUnless(sys.platform == 'darwin', 'AudioUnit lifecycle harness requires macOS SDK')
class AudioLifecycleTests(unittest.TestCase):
    def test_failed_output_suspend_resume_and_media_reset_preserve_pcm(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            run_checked([sys.executable, str(ROOT / 'nxnative/dm/games/game.py'), 'header',
                         '010015100B514000', str(work / 'game_profile.h')])
            executable = work / 'audio-lifecycle'
            run_checked(compiler() + ['-std=c11', '-O1', '-Wno-unused-function',
                        '-I', str(work), '-I', str(HOST),
                        str(ROOT / 'tests/native/wonder_audio_lifecycle.c'),
                        '-framework', 'AudioToolbox', '-o', str(executable)])
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(sys.platform == 'darwin', 'Core Haptics lifecycle harness requires macOS SDK')
class HapticsDriverLifecycleTests(unittest.TestCase):
    def test_retry_spacing_cancellation_and_engine_reset(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / 'haptics-lifecycle'
            run_checked(compiler() + ['-O1', '-fobjc-arc', '-fblocks', '-I', str(HOST),
                        str(ROOT / 'tests/native/wonder_haptics_lifecycle.m'),
                        str(ROOT / 'nxnative/dm/tvos/Sources/vibration.c'),
                        '-framework', 'Foundation', '-framework', 'CoreHaptics',
                        '-framework', 'GameController', '-o', str(executable)])
            for scenario in ('retry', 'spacing', 'cancel-timer', 'cancel-start', 'reset'):
                with self.subTest(scenario=scenario):
                    result = subprocess.run([str(executable), scenario], capture_output=True,
                                            text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
