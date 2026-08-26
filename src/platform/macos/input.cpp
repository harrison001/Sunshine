/**
 * @file src/platform/macos/input.cpp
 * @brief Definitions for libvirtualhid-backed macOS input handling.
 */

// platform includes
#include <ApplicationServices/ApplicationServices.h>

// standard includes
#include <cstdint>
#include <memory>
#include <utility>
#include <vector>

// local includes
#include "src/config.h"
#include "src/logging.h"
#include "src/platform/macos/misc.h"
#include "src/platform/virtualhid_input.h"

namespace platf {

  bool unicode_native(const char *utf8, const int size) {
    if (!utf8 || size <= 0) {
      return false;
    }

    CFStringRef text = CFStringCreateWithBytes(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(utf8), size, kCFStringEncodingUTF8, false);
    if (!text) {
      BOOST_LOG(warning) << "unicode: could not decode "sv << size << " bytes as UTF-8"sv;
      return false;
    }

    const CFIndex length = CFStringGetLength(text);
    std::vector<UniChar> characters(length);
    CFStringGetCharacters(text, CFRangeMake(0, length), characters.data());
    CFRelease(text);

    // A source of our own rather than the default one: events posted from the default source
    // inherit whatever modifiers the machine currently has down, and a held Command turns typed
    // text into menu shortcuts.
    const CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);

    BOOST_LOG(debug) << "unicode: typing "sv << length << " UTF-16 code units"sv;

    for (CFIndex i = 0; i < length; i++) {
      // A surrogate pair is one character in two code units and has to go in one event, or each
      // half arrives as an unpaired surrogate and nothing is typed.
      CFIndex units = 1;
      if (CFStringIsSurrogateHighCharacter(characters[i]) && i + 1 < length && CFStringIsSurrogateLowCharacter(characters[i + 1])) {
        units = 2;
      }

      for (const bool down : {true, false}) {
        CGEventRef event = CGEventCreateKeyboardEvent(source, 0, down);
        if (!event) {
          if (source) {
            CFRelease(source);
          }
          return false;
        }

        CGEventKeyboardSetUnicodeString(event, units, &characters[i]);
        // Cleared, not inherited: what the client is holding down applies to the keys it sends,
        // not to text it has already composed.
        CGEventSetFlags(event, static_cast<CGEventFlags>(0));
        CGEventPost(kCGSessionEventTap, event);
        CFRelease(event);
      }

      i += units - 1;
    }

    if (source) {
      CFRelease(source);
    }
    return true;
  }

  std::optional<util::point_t> get_mouse_loc(input_t & /*input*/) {
    const auto event = CGEventCreate(nullptr);
    if (!event) {
      return std::nullopt;
    }

    const auto current = CGEventGetLocation(event);
    CFRelease(event);
    return util::point_t {current.x, current.y};
  }

  platform_caps::caps_t get_capabilities() {
    platform_caps::caps_t caps = 0;
    const auto runtime = virtualhid::create_runtime();
    if (!runtime) {
      return caps;
    }

    const auto &capabilities = runtime->capabilities();
    if (capabilities.supports_gamepad && virtualhid::configured_gamepad_supports_controller_extensions()) {
      caps |= platform_caps::controller_touch;
    }
    if (config::input.native_pen_touch && (capabilities.supports_touchscreen || capabilities.supports_pen_tablet)) {
      caps |= platform_caps::pen_touch;
    }

    return caps;
  }

  std::vector<supported_gamepad_t> &supported_gamepads(input_t *input) {
    static std::vector<supported_gamepad_t> gamepads;
    if (!input || !input->get()) {
      gamepads = virtualhid::static_supported_gamepads();
      return gamepads;
    }

    gamepads = virtualhid::supported_gamepads(virtualhid::get_input_context(*input).runtime.get());
    return gamepads;
  }

}  // namespace platf
