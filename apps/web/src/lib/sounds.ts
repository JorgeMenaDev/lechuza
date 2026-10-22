// Lechuza's start and stop sounds, synthesised so no audio file ships: two
// soft sine notes a fifth apart, rising when dictation starts and falling
// when it stops. Pure tones, so the microphone picking them up never turns
// into words.

const NOTES = { start: [587.33, 880], stop: [880, 587.33] } as const;

let context: AudioContext | null = null;

export function playSound(kind: keyof typeof NOTES): void {
  context ??= new AudioContext();
  const audio = context;
  NOTES[kind].forEach((frequency, index) => {
    const at = audio.currentTime + index * 0.07;
    const tone = new OscillatorNode(audio, { frequency });
    const volume = new GainNode(audio, { gain: 0 });
    volume.gain.setValueAtTime(0, at);
    volume.gain.linearRampToValueAtTime(0.12, at + 0.01);
    volume.gain.exponentialRampToValueAtTime(0.0001, at + 0.16);
    tone.connect(volume).connect(audio.destination);
    tone.start(at);
    tone.stop(at + 0.18);
  });
}
