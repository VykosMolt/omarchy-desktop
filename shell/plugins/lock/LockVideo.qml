import QtQuick
import QtMultimedia

// The lock screen's looping background video, alone in its own file so the
// QtMultimedia import sits behind a Loader.
Item {
  id: root

  property string videoUrl: ""
  property bool paused: false

  // A frame is on screen. The view keeps the still background up until then,
  // so starting playback never flashes black.
  readonly property bool playing: player.hasVideo

  signal failed()

  onPausedChanged: {
    if (root.paused) player.pause()
    else player.play()
  }

  MediaPlayer {
    id: player
    source: root.videoUrl
    // Playback starts with the media rather than from a completion handler: a
    // play() that runs before the source is bound sits on nothing.
    autoPlay: !root.paused
    loops: MediaPlayer.Infinite
    videoOutput: output

    // No audioOutput. The greeter's video carries a soundtrack, and a lock
    // screen is not the place for one.

    onErrorOccurred: root.failed()
    // A player with nothing loaded yet also reports NoMedia, so only media it
    // cannot make sense of counts.
    onMediaStatusChanged: if (mediaStatus === MediaPlayer.InvalidMedia) root.failed()
  }

  VideoOutput {
    id: output
    anchors.fill: parent
    fillMode: VideoOutput.PreserveAspectCrop
  }
}
