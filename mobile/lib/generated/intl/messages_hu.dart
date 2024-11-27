// DO NOT EDIT. This is code generated via package:intl/generate_localized.dart
// This is a library that provides messages for a hu locale. All the
// messages from the main program should be duplicated here with the same
// function name.

// Ignore issues from commonly used lints in this file.
// ignore_for_file:unnecessary_brace_in_string_interps, unnecessary_new
// ignore_for_file:prefer_single_quotes,comment_references, directives_ordering
// ignore_for_file:annotate_overrides,prefer_generic_function_type_aliases
// ignore_for_file:unused_import, file_names, avoid_escaping_inner_quotes
// ignore_for_file:unnecessary_string_interpolations, unnecessary_string_escapes

import 'package:intl/intl.dart';
import 'package:intl/message_lookup_by_library.dart';

final messages = new MessageLookup();

typedef String MessageIfAbsent(String messageStr, List<dynamic> args);

class MessageLookup extends MessageLookupByLibrary {
  String get localeName => 'hu';

  final messages = _notInlinedMessages(_notInlinedMessages);
  static Map<String, Function> _notInlinedMessages(_) => <String, Function>{
        "accountWelcomeBack":
            MessageLookupByLibrary.simpleMessage("Köszöntjük ismét!"),
        "allow": MessageLookupByLibrary.simpleMessage("Allow"),
        "allowAppToOpenSharedAlbumLinks": MessageLookupByLibrary.simpleMessage(
            "Allow app to open shared album links"),
        "askDeleteReason":
            MessageLookupByLibrary.simpleMessage("Miért törli a fiókját?"),
        "backupFile": MessageLookupByLibrary.simpleMessage("Backup file"),
        "cancel": MessageLookupByLibrary.simpleMessage("Mégse"),
        "deleteAccount": MessageLookupByLibrary.simpleMessage("Fiók törlése"),
        "deleteAccountFeedbackPrompt": MessageLookupByLibrary.simpleMessage(
            "Sajnáljuk, hogy távozik. Kérjük, ossza meg velünk visszajelzéseit, hogy segítsen nekünk a fejlődésben."),
        "email": MessageLookupByLibrary.simpleMessage("E-mail"),
        "enterValidEmail": MessageLookupByLibrary.simpleMessage(
            "Kérjük, adjon meg egy érvényes e-mail címet."),
        "enterYourEmailAddress":
            MessageLookupByLibrary.simpleMessage("Adja meg az e-mail címét"),
        "feedback": MessageLookupByLibrary.simpleMessage("Visszajelzés"),
        "invalidEmailAddress":
            MessageLookupByLibrary.simpleMessage("Érvénytelen e-mail cím"),
        "openAlbumInBrowser":
            MessageLookupByLibrary.simpleMessage("Open album in browser"),
        "openAlbumInBrowserTitle": MessageLookupByLibrary.simpleMessage(
            "Please use the web app to add photos to this album"),
        "openFile": MessageLookupByLibrary.simpleMessage("Open file"),
        "seePublicAlbumLinksInApp": MessageLookupByLibrary.simpleMessage(
            "See public album links in app"),
        "theLinkYouAreTryingToAccessHasExpired":
            MessageLookupByLibrary.simpleMessage(
                "The link you are trying to access has expired."),
        "verify": MessageLookupByLibrary.simpleMessage("Hitelesítés")
      };
}