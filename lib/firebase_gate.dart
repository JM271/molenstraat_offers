import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'brand.dart';
import 'catalog.dart';
import 'firebase_config.dart';
import 'offer_store.dart';

/// User-facing German message for Firebase and other errors.
String cloudError(Object error) {
  if (error is FirebaseException) {
    return switch (error.code) {
      'permission-denied' =>
        'Keine Berechtigung. Bitte Freigabe und Datenbankregeln prüfen.',
      'unavailable' || 'network-request-failed' || 'deadline-exceeded' =>
        'Keine Verbindung. Die Änderung wurde nicht gespeichert. '
            'Bitte erneut versuchen.',
      'invalid-credential' ||
      'wrong-password' ||
      'user-not-found' ||
      'invalid-email' => 'E-Mail oder Passwort ungültig.',
      'email-already-in-use' => 'Für diese E-Mail besteht bereits ein Konto.',
      'weak-password' =>
        'Bitte ein stärkeres Passwort wählen (mindestens 6 Zeichen).',
      'too-many-requests' =>
        'Zu viele Versuche. Bitte später erneut versuchen.',
      _ => 'Vorgang fehlgeschlagen (${error.code}). Bitte erneut versuchen.',
    };
  }
  return 'Vorgang fehlgeschlagen. Bitte erneut versuchen.';
}

/// Connects to Firebase, signs the user in and checks the membership of the
/// Molenstraat workshop, the same accounts and approval as the Inventory app.
class FirebaseGate extends StatefulWidget {
  const FirebaseGate({super.key, required this.builder});

  final Widget Function(OfferStore store) builder;

  @override
  State<FirebaseGate> createState() => _FirebaseGateState();
}

class _FirebaseGateState extends State<FirebaseGate> {
  late final Future<void> _initialization = _initialize();

  Future<void> _initialize() async {
    if (!OffersFirebaseConfig.configured) {
      throw StateError('Firebase ist für diese Plattform nicht eingerichtet.');
    }
    await Firebase.initializeApp(options: OffersFirebaseConfig.options);
    // Like Inventory: no persistent cache of another account's data, and no
    // offline writes that look saved but are not.
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: false,
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _initialization,
    builder: (context, init) {
      if (init.hasError) {
        return const _Message(
          'Firebase ist für diese Plattform nicht eingerichtet. '
          'Die App läuft auf Android, iPhone und im Browser.',
          signedIn: false,
        );
      }
      if (init.connectionState != ConnectionState.done) return const _Loading();
      return StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, auth) {
          if (auth.hasError) {
            return const _Message(
              'Anmeldestatus konnte nicht geladen werden. '
              'Bitte App neu starten.',
            );
          }
          if (auth.connectionState == ConnectionState.waiting) {
            return const _Loading();
          }
          final user = auth.data;
          if (user == null) return const LoginPage();
          return _MembershipGate(
            key: ValueKey(user.uid),
            user: user,
            builder: widget.builder,
          );
        },
      );
    },
  );
}

class _MembershipGate extends StatefulWidget {
  const _MembershipGate({super.key, required this.user, required this.builder});

  final User user;
  final Widget Function(OfferStore store) builder;

  @override
  State<_MembershipGate> createState() => _MembershipGateState();
}

class _MembershipGateState extends State<_MembershipGate> {
  FirebaseFirestore get _db => FirebaseFirestore.instance;

  // The profile lets admins find the account in Inventory → Nutzer verwalten.
  late final Future<void> _profile = _db
      .collection('users')
      .doc(widget.user.uid)
      .set({'email': widget.user.email ?? ''});
  late final Stream<DocumentSnapshot<Map<String, dynamic>>> _membership = _db
      .collection('workshops')
      .doc(OfferStore.workshopId)
      .collection('members')
      .doc(widget.user.uid)
      .snapshots(includeMetadataChanges: true);
  OfferStore? _store;

  /// Opens the shared data, links the catalogue's supplier numbers for the
  /// stock lookup and brings the database's prices up to the bundled
  /// Molenstraat product list. A failed sync only means it runs again on the
  /// next start.
  OfferStore _openStore() {
    final store = OfferStore(_db, widget.user.uid);
    loadCatalog()
        .then((catalog) {
          store.useCatalog(catalog);
          return store.syncListPrices(catalog);
        })
        .catchError((Object e) {
          debugPrint('Listenpreise nicht synchronisiert: $e');
          return 0;
        });
    return store;
  }

  @override
  void dispose() {
    _store?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _profile,
    builder: (context, registered) {
      if (registered.hasError) return _Message(cloudError(registered.error!));
      if (registered.connectionState != ConnectionState.done) {
        return const _Loading();
      }
      return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: _membership,
        builder: (context, snapshot) {
          if (snapshot.hasError) return _Message(cloudError(snapshot.error!));
          if (!snapshot.hasData) return const _Loading();
          if (snapshot.data!.metadata.isFromCache) {
            return const _Message(
              'Verbindung wird hergestellt. Für die Prüfung deiner Freigabe '
              'wird Internet benötigt.',
            );
          }
          final role = snapshot.data!.data()?['role'];
          if (role != 'admin' && role != 'editor') {
            _store?.dispose();
            _store = null;
            return _PendingPage(user: widget.user);
          }
          final store = _store ??= _openStore();
          return widget.builder(store);
        },
      );
    },
  );
}

class _PendingPage extends StatelessWidget {
  const _PendingPage({required this.user});

  final User user;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Freigabe ausstehend'),
      actions: const [SignOutButton()],
    ),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(user.email ?? ''),
        const SizedBox(height: 16),
        const Text(
          'Dein Konto ist angelegt. Ein Administrator muss dich noch in der '
          'Inventar-App (Spoke) unter „Nutzer verwalten“ freigeben. Danach '
          'hast du Zugriff auf Lager und Angebote.',
        ),
        const SizedBox(height: 16),
        SelectableText('Benutzer-ID: ${user.uid}'),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: user.uid)),
            icon: const Icon(Icons.copy),
            label: const Text('Benutzer-ID kopieren'),
          ),
        ),
      ],
    ),
  );
}

class SignOutButton extends StatelessWidget {
  const SignOutButton({super.key});

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Abmelden',
    icon: const Icon(Icons.logout),
    onPressed: () => FirebaseAuth.instance.signOut(),
  );
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _register = false;
  bool _busy = false;
  String? _error;
  String? _message;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit({bool reset = false}) async {
    if (_busy || (!reset && !_form.currentState!.validate())) return;
    if (reset && !_email.text.contains('@')) {
      setState(() => _error = 'Bitte zuerst deine E-Mail-Adresse eingeben.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final auth = FirebaseAuth.instance;
      final email = _email.text.trim();
      if (reset) {
        await auth.sendPasswordResetEmail(email: email);
        if (mounted) {
          setState(
            () => _message =
                'Falls ein Konto existiert, erhältst du eine E-Mail zum '
                'Zurücksetzen.',
          );
        }
      } else if (_register) {
        await auth.createUserWithEmailAndPassword(
          email: email,
          password: _password.text,
        );
      } else {
        await auth.signInWithEmailAndPassword(
          email: email,
          password: _password.text,
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = cloudError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const BrandLogo(height: 26)),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Form(
          key: _form,
          child: AutofillGroup(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(24),
              children: [
                Text(
                  _register ? 'Konto anlegen' : 'Anmelden',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                const Text('Dasselbe Konto wie in der Inventar-App (Spoke).'),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _email,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'E-Mail'),
                  validator: (v) =>
                      v != null && v.contains('@') ? null : 'E-Mail eingeben',
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  autofillHints: [
                    _register
                        ? AutofillHints.newPassword
                        : AutofillHints.password,
                  ],
                  decoration: const InputDecoration(labelText: 'Passwort'),
                  validator: (v) =>
                      (v?.length ?? 0) >= 6 ? null : 'Mindestens 6 Zeichen',
                  onFieldSubmitted: (_) => _submit(),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (_message != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(_message!),
                  ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Text(
                    _busy
                        ? 'Bitte warten …'
                        : _register
                        ? 'Konto anlegen'
                        : 'Anmelden',
                  ),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _register = !_register;
                          _error = null;
                          _message = null;
                        }),
                  child: Text(
                    _register
                        ? 'Bereits ein Konto? Anmelden'
                        : 'Neues Konto anlegen',
                  ),
                ),
                TextButton(
                  onPressed: _busy ? null : () => _submit(reset: true),
                  child: const Text('Passwort vergessen?'),
                ),
                if (_register)
                  const Text(
                    'Neue Konten brauchen die Freigabe eines Administrators '
                    'in der Inventar-App.',
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

class _Message extends StatelessWidget {
  const _Message(this.text, {this.signedIn = true});

  final String text;
  final bool signedIn;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const BrandLogo(height: 26),
      actions: [if (signedIn) const SignOutButton()],
    ),
    body: Padding(padding: const EdgeInsets.all(24), child: Text(text)),
  );
}
