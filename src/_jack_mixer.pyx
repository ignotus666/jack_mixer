#
# cython: language_level=3
#
"""Python bindings for jack_mixer.c and scale.c using Cython."""

__all__ = ("Scale", "Mixer")

import enum

from _jack_mixer cimport *


cdef void midi_change_callback_func(void *userdata) with gil:
    """Wrapper for a Python callback function for MIDI input."""
    channel = <object> userdata
    channel._midi_change_callback()


class MidiBehaviour(enum.IntEnum):
    """MIDI control behaviour.

    `JUMP_TO_VALUE`

    Received MIDI control messages affect mixer directly.

    `PICK_UP`

    Received MIDI control messages have to match up with current
    mixer value first (within a small margin), before further
    changes take effect.
    """
    JUMP_TO_VALUE = 0
    PICK_UP = 1


cdef class Scale:
    """Mixer level scale representation.

    Wraps `jack_mixer_scale_t` struct.
    """

    cdef jack_mixer_scale_t _scale

    def __cinit__(self):
        self._scale = scale_create()

    def __dealloc__(self):
        if self._scale:
            scale_destroy(self._scale)

    cpdef bool add_threshold(self, float db, float scale_value):
        """Add scale treshold."""
        return scale_add_threshold(self._scale, db, scale_value)

    cpdef void remove_thresholds(self):
        """Remove scale threshold."""
        scale_remove_thresholds(self._scale)

    cpdef void calculate_coefficients(self):
        """Calculate scale coefficents."""
        scale_calculate_coefficients(self._scale)

    cpdef double db_to_scale(self, double db):
        """Return scale value responding to given dB value."""
        return scale_db_to_scale(self._scale, db)

    cpdef double scale_to_db(self, double scale_value):
        """Return dB value responding to given scale value."""
        return scale_scale_to_db(self._scale, scale_value)


cdef class Mixer:
    """Jack Mixer representation.

    Wraps `jack_mixer_t` struct.
    """

    cdef jack_mixer_t _mixer
    cdef bool _stereo

    def __cinit__(self, name, stereo=True):
        self._stereo = stereo
        self._mixer = mixer_create(name.encode('utf-8'), stereo)

    def __dealloc__(self):
        if self._mixer:
            mixer_destroy(self._mixer)

    def destroy(self):
        """Close mixer Jack client and detroy mixer instance.

        The instance must not be used anymore after calling this
        method.
        """
        if self._mixer:
            mixer_destroy(self._mixer)

    @property
    def channels_count(self):
        """Number of mixer channels."""
        return mixer_get_channels_count(self._mixer)

    @property
    def client_name(self):
        """Jack client name of mixer."""
        return mixer_get_client_name(self._mixer).decode('utf-8')

    @property
    def last_midi_cc(self):
        """Last received MIDI control change message."""
        return mixer_get_last_midi_cc(self._mixer)

    @last_midi_cc.setter
    def last_midi_cc(self, int channel):
        mixer_set_last_midi_cc(self._mixer, channel)

    @property
    def midi_behavior_mode(self):
        """MIDI control change behaviour mode.

        See `MidiBehaviour` enum for more information.
        """
        return MidiBehaviour(mixer_get_midi_behavior_mode(self._mixer))

    @midi_behavior_mode.setter
    def midi_behavior_mode(self, mode):
        mixer_set_midi_behavior_mode(self._mixer,
                                     mode.value if isinstance(mode, MidiBehaviour) else mode)

    cpdef add_channel(self, channel_name, stereo=None):
        """Add a stereo or mono input channel with given name to the mixer.

        Returns a `Channel` instance.
        """
        if stereo is None:
            stereo = self._stereo

        return Channel.new(mixer_add_channel(self._mixer, channel_name.encode('utf-8'), stereo))

    cpdef add_output_channel(self, channel_name, stereo=None, system=False):
        """Add a stereo or mono output channel with given name to the mixer.

        Returns a `OutputChannel` instance.
        """
        if stereo is None:
            stereo = self._stereo

        return OutputChannel.new(mixer_add_output_channel(self._mixer,
                                                          channel_name.encode('utf-8'),
                                                          stereo, system))


cdef class Channel:
    """Jack Mixer (input) channel representation.

    Wraps `jack_mixer_channel_t` struct.
    """

    cdef jack_mixer_channel_t _channel
    cdef object _midi_change_callback

    def __init__(self):
        raise TypeError("Channel instances can only be created via Mixer.add_channel().")

    @staticmethod
    cdef Channel new(jack_mixer_channel_t chan_ptr):
        """Create a new Channel instance.

        A pointer to an initialzed `jack_mixer_channel_t` struct must be
        passed in.

        This should not be called directly but only via `Mixer.add_channel()`.
        """
        cdef Channel channel = Channel.__new__(Channel)
        channel._channel = chan_ptr
        return channel

    @property
    def abspeak(self):
        """Absolute peak of channel meter.

        Set to `None` to reset the absolute peak to -inf.
        Trying to set it to any other value will raise a `ValueError`.
        """
        return channel_abspeak_read(self._channel)

    @abspeak.setter
    def abspeak(self, reset):
        if reset is not None:
            raise ValueError("abspeak can only be reset (set to None)")
        channel_abspeak_reset(self._channel)

    @property
    def balance(self):
        """Channel balance property."""
        return channel_balance_read(self._channel)

    @balance.setter
    def balance(self, double bal):
        channel_balance_write(self._channel, bal)

    @property
    def is_stereo(self):
        """Is channel stereo or mono?"""
        return channel_is_stereo(self._channel)

    @property
    def kmeter(self):
        """Read channel kmeter.

        If channel is stereo, return a four-item tupel with
        ``(peak_left, peak_right, rms_left, rms_right)`` value.
        If channel is mono, return a tow-item tupel with ``(peak, rms)`` value.
        """
        cdef double peak_left, peak_right, left_rms, right_rms

        if channel_is_stereo(self._channel):
            channel_stereo_kmeter_read(
                self._channel, &peak_left, &peak_right, &left_rms, &right_rms)
            return (peak_left, peak_right, left_rms, right_rms)
        else:
            channel_mono_kmeter_read(self._channel, &peak_left, &left_rms)
            return (peak_left, left_rms)

    @property
    def meter(self):
        """Read channel meter.

        If channel is stereo, return a two-item tupel with (left, right) value.
        If channel is mono, return a tupel with the value as the only item.
        """
        cdef double left, right

        if channel_is_stereo(self._channel):
            channel_stereo_meter_read(self._channel, &left, &right)
            return (left, right)
        else:
            channel_mono_meter_read(self._channel, &left)
            return (left,)

    @property
    def midi_change_callback(self):
        """Function to be called when a channel property is changed via MIDI.

        The callback function takes no arguments.

        Assign `None` to remove any existing callback.
        """
        return self._midi_change_callback

    @midi_change_callback.setter
    def midi_change_callback(self, callback):
        self._midi_change_callback = callback
        if callback is None:
            channel_set_midi_change_callback(self._channel, NULL, NULL)
        else:
            channel_set_midi_change_callback(self._channel,
                                             &midi_change_callback_func,
                                             <void *>self)

    @property
    def name(self):
        """Channel name property."""
        return channel_get_name(self._channel).decode('utf-8')

    @name.setter
    def name(self, newname):
        channel_rename(self._channel, newname.encode('utf-8'))

    @property
    def out_mute(self):
        """Channel solo status property."""
        return channel_is_out_muted(self._channel)

    @out_mute.setter
    def out_mute(self, bool value):
        if value:
            channel_out_mute(self._channel)
        else:
            channel_out_unmute(self._channel)

    @property
    def solo(self):
        """Channel solo status property."""
        return channel_is_soloed(self._channel)

    @solo.setter
    def solo(self, bool value):
        if value:
            channel_solo(self._channel)
        else:
            channel_unsolo(self._channel)

    @property
    def midi_in_got_events(self):
        """Did channel receive any MIDI events assigned to one of its controls?

        Reading this property also resets it to False.
        """
        return channel_get_midi_in_got_events(self._channel)

    @property
    def midi_scale(self):
        """MIDI scale used by channel."""
        raise AttributeError("midi_scale can only be set.")

    @midi_scale.setter
    def midi_scale(self, Scale scale):
        channel_set_midi_scale(self._channel, scale._scale)

    @property
    def volume(self):
        """Channel volume property."""
        return channel_volume_read(self._channel)

    @volume.setter
    def volume(self, double vol):
        channel_volume_write(self._channel, vol)

    @property
    def balance_midi_cc(self):
        """MIDI CC assigned to control channel balance."""
        return channel_get_balance_midi_cc(self._channel)

    @balance_midi_cc.setter
    def balance_midi_cc(self, int cc):
        channel_set_balance_midi_cc(self._channel, cc)

    @property
    def mute_midi_cc(self):
        """MIDI CC assigned to control channel mute status."""
        return channel_get_mute_midi_cc(self._channel)

    @mute_midi_cc.setter
    def mute_midi_cc(self, int cc):
        channel_set_mute_midi_cc(self._channel, cc)

    @property
    def solo_midi_cc(self):
        """MIDI CC assigned to control channel solo status."""
        return channel_get_solo_midi_cc(self._channel)

    @solo_midi_cc.setter
    def solo_midi_cc(self, int cc):
        channel_set_solo_midi_cc(self._channel, cc)

    @property
    def volume_midi_cc(self):
        """MIDI CC assigned to control channel volume."""
        return channel_get_volume_midi_cc(self._channel)

    @volume_midi_cc.setter
    def volume_midi_cc(self, int cc):
        channel_set_volume_midi_cc(self._channel, cc)

    def autoset_balance_midi_cc(self):
        """Auto assign MIDI CC for channel balance."""
        channel_autoset_balance_midi_cc(self._channel)

    def autoset_mute_midi_cc(self):
        """Auto assign MIDI CC for channel mute status."""
        channel_autoset_mute_midi_cc(self._channel)

    def autoset_solo_midi_cc(self):
        """Auto assign MIDI CC for channel solo status."""
        channel_autoset_solo_midi_cc(self._channel)

    def autoset_volume_midi_cc(self):
        """Auto assign MIDI CC for channel volume."""
        channel_autoset_volume_midi_cc(self._channel)

    def remove(self):
        """Remove channel."""
        remove_channel(self._channel)

    def set_midi_cc_balance_picked_up(self, bool status):
        """Set whether balance value is out-of-sync with MIDI control."""
        channel_set_midi_cc_balance_picked_up(self._channel, status)

    def set_midi_cc_volume_picked_up(self, bool status):
        """Set whether volume value is out-of-sync with MIDI control."""
        channel_set_midi_cc_volume_picked_up(self._channel, status)



cdef class OutputChannel(Channel):
    """Jack Mixer output channel representation.

    Wraps `jack_mixer_output_channel_t` struct.

    Inherits from `Channel` class.
    """

    cdef jack_mixer_output_channel_t _output_channel

    def __init__(self):
        raise TypeError("OutputChannel instances can only be created via "
                        "Mixer.add_output_channel().")

    @staticmethod
    cdef OutputChannel new(jack_mixer_output_channel_t chan_ptr):
        """Create a new OutputChannel instance.

        A pointer to an initialzed `jack_mixer_output_channel_t` struct must
        be passed in.

        This should not be called directly but only via
        `Mixer.add_output_channel()`.
        """
        cdef OutputChannel channel = OutputChannel.__new__(OutputChannel)
        channel._output_channel = chan_ptr
        channel._channel = <jack_mixer_channel_t> chan_ptr
        return channel

    @property
    def prefader(self):
        return output_channel_is_prefader(self._output_channel)

    @prefader.setter
    def prefader(self, bool pfl):
        output_channel_set_prefader(self._output_channel, pfl)

    def is_in_prefader(self, Channel channel):
        """Is a channel set as prefader?"""
        return output_channel_is_in_prefader(self._output_channel, channel._channel)

    def set_in_prefader(self, Channel channel, bool value):
        """Set a channel as prefader."""
        output_channel_set_in_prefader(self._output_channel, channel._channel, value)

    def is_muted(self, Channel channel):
        """Is a channel set as muted?"""
        return output_channel_is_muted(self._output_channel, channel._channel)

    def set_muted(self, Channel channel, bool value):
        """Set a channel as muted."""
        output_channel_set_muted(self._output_channel, channel._channel, value)

    def is_solo(self, Channel channel):
        """Is a channel set as solo?"""
        return output_channel_is_solo(self._output_channel, channel._channel)

    def set_solo(self, Channel channel, bool value):
        """Set a channel as solo."""
        output_channel_set_solo(self._output_channel, channel._channel, value)

    def remove(self):
        """Remove output channel."""
        remove_output_channel(self._output_channel)