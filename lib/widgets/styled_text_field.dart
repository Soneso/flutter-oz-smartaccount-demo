/// Validated text field with touch-aware error state.
library;

import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// StyledTextField
// ---------------------------------------------------------------------------

/// A Material 3 styled text field that shows validation errors only after
/// the user has interacted with the field (focus-aware validation).
///
/// Behaviour:
/// - Validation runs on every change via [validator].
/// - Error text is shown only after the field has been focused and then
///   unfocused at least once (touch-aware error state via [FocusNode]).
/// - When [enabled] is false the field renders in a disabled style and
///   ignores all input.
///
/// Accessibility:
/// - [label] is used as the semantic label and the floating label text.
/// - Error text is announced by screen readers when it appears.
///
/// Usage:
/// ```dart
/// StyledTextField(
///   controller: _usernameController,
///   label: 'Username',
///   hint: 'Enter your display name',
///   validator: (v) => v.isEmpty ? 'Username is required' : null,
/// )
/// ```
class StyledTextField extends StatefulWidget {
  /// Creates a [StyledTextField].
  const StyledTextField({
    required this.controller,
    required this.label,
    this.hint,
    this.validator,
    this.enabled = true,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    super.key,
  });

  /// Text editing controller for this field.
  final TextEditingController controller;

  /// Floating label text and accessibility label.
  final String label;

  /// Optional placeholder text shown when the field is empty and unfocused.
  final String? hint;

  /// Optional validation function.
  ///
  /// Called on every text change. Return a non-null string to show an error.
  /// Errors are only displayed after the field has been focused and unfocused.
  final String? Function(String value)? validator;

  /// Whether the field accepts input.
  final bool enabled;

  /// Keyboard type hint for the platform keyboard.
  final TextInputType? keyboardType;

  /// IME action for the platform keyboard (e.g. [TextInputAction.done]).
  final TextInputAction? textInputAction;

  /// Called when the user submits the field (e.g. presses the IME action).
  final void Function(String value)? onSubmitted;

  @override
  State<StyledTextField> createState() => _StyledTextFieldState();
}

class _StyledTextFieldState extends State<StyledTextField> {
  late final FocusNode _focusNode;

  /// True after the field has been focused at least once.
  bool _hasBeenFocused = false;

  /// True while the field currently has focus.
  bool _isFocused = false;

  String? _errorText;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode()..addListener(_onFocusChange);
    widget.controller.addListener(_onTextChange);
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_onFocusChange)
      ..dispose();
    widget.controller.removeListener(_onTextChange);
    super.dispose();
  }

  void _onFocusChange() {
    final nowFocused = _focusNode.hasFocus;
    setState(() {
      if (nowFocused) {
        _hasBeenFocused = true;
      }
      _isFocused = nowFocused;
      _validate();
    });
  }

  void _onTextChange() {
    setState(_validate);
  }

  void _validate() {
    final validator = widget.validator;
    if (validator == null) {
      _errorText = null;
      return;
    }
    // Show errors only after the user has interacted with the field.
    if (!_hasBeenFocused || _isFocused) {
      _errorText = null;
      return;
    }
    _errorText = validator(widget.controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: widget.label,
      child: TextField(
        controller: widget.controller,
        focusNode: _focusNode,
        enabled: widget.enabled,
        keyboardType: widget.keyboardType,
        textInputAction: widget.textInputAction,
        onSubmitted: widget.onSubmitted,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          errorText: _errorText,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
