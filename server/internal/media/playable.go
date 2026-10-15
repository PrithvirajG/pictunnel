package media

// Playable is the 2B browser-playable rule: container mp4/mov with an h264
// video stream, or webm with vp8/vp9/av1, and audio absent or aac/opus/mp3.
func Playable(p Probe) bool {
	switch p.Container {
	case "mp4", "mov":
		if p.VideoCodec != "h264" {
			return false
		}
	case "webm":
		switch p.VideoCodec {
		case "vp8", "vp9", "av1":
		default:
			return false
		}
	default:
		return false
	}
	switch p.AudioCodec {
	case "", "aac", "opus", "mp3":
		return true
	}
	return false
}
