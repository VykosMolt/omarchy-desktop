import QtQuick
import qs.Commons

// The lock screen, wearing the Night City greeter's look so locking the session
// and logging into it are the same screen: the greeter's looping video under a
// dark wash and its rain, the pixel clock on the left, and the name and
// underlined password field along the bottom.
//
// The assets are the greeter's own, so the two stay in step and this checkout
// carries no second copy of a twelve megabyte video. Neither is required: a
// missing video falls back to the session background and a missing font to the
// shell's. A lock screen that cannot paint is one nobody can type a password
// into.
Item {
  id: root

  readonly property string themePath: "/usr/share/sddm/themes/Night_City"

  property string backgroundPath: ""
  property int backgroundVersion: 0
  property string userName: ""
  property bool fingerprintConfigured: false
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property string passwordText: ""
  property bool syncingPasswordText: false
  // The display is blanked: nothing here is on screen, so stop painting it.
  property bool paused: false
  property bool videoFailed: false
  property date now: new Date()

  // The greeter scales everything off a 768-tall reference screen.
  readonly property real s: Math.max(1, height) / 768

  readonly property color signTeal: "#50c8d8"
  readonly property color signPink: "#d06880"
  readonly property color textWhite: "#e8e4f0"
  readonly property color errorRed: "#ff4444"

  readonly property string fontFamily: pixelFont.status === FontLoader.Ready ? pixelFont.name : Style.font.family
  readonly property int fieldWidth: Math.round(360 * s)
  readonly property int fieldFontSize: Math.max(1, Math.round(12 * s))
  readonly property int passwordDotFontSize: Math.max(1, Math.round(18 * s))
  readonly property real passwordDotLetterSpacing: 6 * s
  // Space kept clear on each side of the field for the fingerprint icon, so the
  // centred mask never runs under it.
  readonly property real fingerprintReserve: fingerprintConfigured ? Math.round(fingerprintIcon.implicitWidth + 12 * s) : 0
  // Shrink the mask to fit once the password outgrows the field: the greeter
  // clips instead, which leaves a long password with no feedback at all.
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, Math.max(1, passwordInput.width - 4 * s) / dotMetrics.advanceWidth)
    : 1

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()

  // Cache-busts the background by appending `?v=`, so picking a new one
  // mid-session reloads it.
  function fileUrl(path, version) {
    if (!path) return ""
    var url = "file://" + String(path).split("/").map(encodeURIComponent).join("/")
    return version === undefined ? url : url + "?v=" + version
  }

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: if (inputEnabled) Qt.callLater(forcePasswordFocus)
  Component.onCompleted: {
    syncPasswordText()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  FontLoader {
    id: pixelFont
    source: root.fileUrl(root.themePath + "/font/PixelifySans-Bold.ttf")
  }

  TextMetrics {
    id: dotMetrics
    font.family: root.fontFamily
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "─".repeat(passwordInput.text.length)
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.loadBackground && !root.paused
    onTriggered: root.now = new Date()
    // The wake that unblanks the panel re-reads the clock before the first
    // tick, so it is never a minute behind on wake.
    onRunningChanged: if (running) root.now = new Date()
  }

  Rectangle {
    anchors.fill: parent
    color: "#060810"

    // The session background stands in for the video: while it loads, when the
    // greeter is not installed, and when the machine cannot decode one.
    Image {
      anchors.fill: parent
      visible: !video.item || !video.item.playing
      source: root.loadBackground ? root.fileUrl(root.backgroundPath, root.backgroundVersion) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    // By URL, so a machine without QtMultimedia loses the video rather than the
    // password field.
    Loader {
      id: video
      anchors.fill: parent
      active: root.loadBackground && !root.videoFailed
      source: "LockVideo.qml"

      onLoaded: {
        item.videoUrl = root.fileUrl(root.themePath + "/bg.mp4")
        item.paused = Qt.binding(function() { return root.paused })
        item.failed.connect(function() { root.videoFailed = true })
      }
      onStatusChanged: if (status === Loader.Error) root.videoFailed = true
    }

    Rectangle {
      anchors.fill: parent
      color: "black"
      opacity: 0.3
    }

    // Rain. It stops with the display: a locked laptop should not be painting
    // forty falling drops into a panel that is switched off.
    Repeater {
      model: 40

      delegate: Rectangle {
        id: drop

        readonly property int fall: 800 + Math.round(Math.random() * 1200)
        readonly property real length: (20 + Math.random() * 30) * root.s

        x: Math.random() * root.width
        width: Math.max(1, root.s)
        height: length
        opacity: 0
        gradient: Gradient {
          GradientStop { position: 0.0; color: "transparent" }
          GradientStop { position: 1.0; color: "#8050c8d8" }
        }

        SequentialAnimation {
          running: root.loadBackground && !root.paused
          loops: Animation.Infinite

          PauseAnimation { duration: Math.round(Math.random() * 3000) }

          ParallelAnimation {
            NumberAnimation { target: drop; property: "y"; from: -drop.length; to: root.height + drop.length; duration: drop.fall }

            SequentialAnimation {
              NumberAnimation { target: drop; property: "opacity"; to: 0.6; duration: Math.round(drop.fall * 0.1) }
              PauseAnimation { duration: Math.round(drop.fall * 0.8) }
              NumberAnimation { target: drop; property: "opacity"; to: 0; duration: Math.round(drop.fall * 0.1) }
            }
          }
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
      onPositionChanged: root.wakeRequested()
    }

    Column {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.margins: Math.round(60 * root.s)
      spacing: Math.round(10 * root.s)

      Row {
        spacing: Math.round(20 * root.s)

        Label {
          text: Qt.formatTime(root.now, "HH")
          color: "white"
          size: Math.round(100 * root.s)
          spacing: -5 * root.s
        }

        Rectangle {
          width: Math.round(4 * root.s)
          height: Math.round(80 * root.s)
          radius: Math.round(2 * root.s)
          color: root.signPink
          anchors.verticalCenter: parent.verticalCenter
        }

        Label {
          text: Qt.formatTime(root.now, "mm")
          color: root.signTeal
          size: Math.round(100 * root.s)
          spacing: -5 * root.s
        }
      }

      Label {
        text: Qt.formatDate(root.now, "dddd, MMMM d").toUpperCase()
        color: "white"
        opacity: 0.8
        size: root.fieldFontSize
        spacing: 8 * root.s
      }
    }

    Column {
      anchors.bottom: parent.bottom
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottomMargin: Math.round(80 * root.s)
      width: root.fieldWidth
      spacing: Math.round(30 * root.s)

      Label {
        anchors.horizontalCenter: parent.horizontalCenter
        text: (root.userName || "user").toUpperCase()
        color: root.textWhite
        size: Math.max(1, Math.round(22 * root.s))
        spacing: 6 * root.s
      }

      Item {
        width: parent.width
        height: Math.round(40 * root.s)

        Rectangle {
          anchors.bottom: parent.bottom
          width: parent.width
          height: Math.max(1, root.s)
          color: root.failureMessage ? root.errorRed : root.signPink
          opacity: passwordInput.activeFocus ? 1.0 : 0.3
        }

        Rectangle {
          anchors.bottom: parent.bottom
          width: passwordInput.activeFocus ? parent.width : 0
          height: Math.max(1, Math.round(2 * root.s))
          color: root.failureMessage ? root.errorRed : root.signPink

          Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutExpo } }
        }

        TextInput {
          id: passwordInput
          anchors.fill: parent
          anchors.leftMargin: root.fingerprintReserve
          anchors.rightMargin: root.fingerprintReserve
          horizontalAlignment: TextInput.AlignHCenter
          verticalAlignment: TextInput.AlignVCenter
          activeFocusOnPress: true
          clip: true
          enabled: root.inputEnabled && !root.authenticatingPassword
          readOnly: root.authenticatingPassword
          echoMode: TextInput.Password
          passwordCharacter: "─"
          passwordMaskDelay: 0
          color: root.signPink
          selectionColor: root.signPink
          selectedTextColor: root.textWhite
          font.family: root.fontFamily
          font.pixelSize: Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale))
          font.letterSpacing: root.passwordDotLetterSpacing * root.passwordDotScale
          cursorVisible: false
          cursorDelegate: Item { }

          onTextChanged: {
            if (!root.syncingPasswordText) root.passwordTextEdited(text)
            if (text.length > 0) root.wakeRequested()
            if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
          }

          onAccepted: {
            var submitted = root.passwordText
            root.passwordTextEdited("")
            if (submitted.length > 0) root.submitPassword(submitted)
          }

          Keys.onPressed: function(event) {
            root.wakeRequested()
            if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
              root.passwordTextEdited("")
              event.accepted = true
            }
          }
        }

        Label {
          anchors.centerIn: parent
          visible: passwordInput.text.length === 0
          text: root.authenticatingPassword ? "CHECKING..." : "UNLOCK"
          color: root.signTeal
          opacity: 0.3
          size: root.fieldFontSize
          spacing: 4 * root.s
        }

        Rectangle {
          id: caret
          width: Math.max(1, Math.round(2 * root.s))
          height: Math.round(20 * root.s)
          color: root.signPink
          anchors.verticalCenter: parent.verticalCenter
          x: passwordInput.x + passwordInput.cursorRectangle.x
          visible: passwordInput.activeFocus && !root.paused

          SequentialAnimation {
            running: caret.visible
            loops: Animation.Infinite

            NumberAnimation { target: caret; property: "opacity"; from: 1; to: 0.05; duration: 450 }
            NumberAnimation { target: caret; property: "opacity"; from: 0.05; to: 1; duration: 450 }
          }
        }

        // Pinned inside the field's right edge when a sensor is enrolled, the
        // way hyprlock places it.
        Text {
          id: fingerprintIcon
          objectName: "fingerprintIndicator"
          textFormat: Text.PlainText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: root.fingerprintConfigured
          text: "󰈷"
          color: root.signTeal
          // The shell's font, not the greeter's: the pixel font has no icons.
          font.family: Style.font.family
          font.pixelSize: Math.round(root.passwordDotFontSize * 1.1)
        }
      }

      // The service's message says an attempt failed and how many have; the
      // greeter's own wording says it here.
      Label {
        anchors.horizontalCenter: parent.horizontalCenter
        visible: root.failureMessage.length > 0
        text: root.failedAttempts > 1 ? "PERMISSION DENIED (" + root.failedAttempts + ")" : "PERMISSION DENIED"
        color: root.errorRed
        size: root.fieldFontSize
        spacing: 4 * root.s
      }
    }
  }

  // Every label the greeter draws carries a drop shadow so it stays legible
  // over whatever the video is showing.
  component Label: Text {
    property int size: 12
    property real spacing: 0

    textFormat: Text.PlainText
    style: Text.Raised
    styleColor: "#80000000"
    font.family: root.fontFamily
    font.pixelSize: size
    font.letterSpacing: spacing
  }
}
