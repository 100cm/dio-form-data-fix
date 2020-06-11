import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'multipart_file.dart';
import 'utils.dart';

/// A class to create readable "multipart/form-data" streams.
/// It can be used to submit forms and file uploads to http server.
class FormData {
  static const String _BOUNDARY_PRE_TAG = '--dio-boundary-';
  static const _BOUNDARY_LENGTH = _BOUNDARY_PRE_TAG.length + 10;

  String _boundary;

  /// The boundary of FormData, it consists of a constant prefix and a random
  /// postfix to assure the the boundary unpredictable and unique, each FormData
  /// instance will be different.
  String get boundary => _boundary;

  final _newlineRegExp = RegExp(r'\r\n|\r|\n');

  /// The form fields to send for this request.
  final fields = <MapEntry<String, String>>[];

  /// The [files].
  final files = <MapEntry<String, MultipartFile>>[];
  final all_fields = <MapEntry<Map<String, dynamic>, dynamic>>[];

  /// Whether [finalize] has been called.
  bool get isFinalized => _isFinalized;
  bool _isFinalized = false;

  FormData() {
    _init();
  }

  /// Create FormData instance with a Map.
  FormData.fromMap(Map<String, dynamic> map) {
    _init();
    encodeMap(
      map,
          (key, value) {
        if (value == null) return null;
        var is_file = false;
        if (value is MultipartFile) {
          files.add(MapEntry(key, value));
          all_fields.add(MapEntry({"key": key, "is_file": true}, value));
        } else {
          all_fields.add(
              MapEntry({"key": key, "is_file": false}, value.toString()));
          fields.add(MapEntry(key, value.toString()));
        }
        return null;
      },
      encode: false,
    );
  }

  void _init() {
    // Assure the boundary unpredictable and unique
    var random = Random();
    _boundary = _BOUNDARY_PRE_TAG +
        random.nextInt(4294967296).toString().padLeft(10, '0');
  }

  /// Returns the header string for a field. The return value is guaranteed to
  /// contain only ASCII characters.
  String _headerForField(String name, String value) {
    var header =
        'content-disposition: form-data; name="${_browserEncode(name)}"';
    if (!isPlainAscii(value) && value != '') {
      header = '$header\r\n'
          'content-type: text/plain; charset=utf-8\r\n'
          'content-transfer-encoding: binary';
    }
    return '$header\r\n\r\n';
  }

  /// Returns the header string for a file. The return value is guaranteed to
  /// contain only ASCII characters.
  String _headerForFile(MapEntry<String, MultipartFile> entry) {
    var file = entry.value;
    var header =
        'content-disposition: form-data; name="${_browserEncode(entry.key)}"';
    if (file.filename != null) {
      header = '$header; filename="${_browserEncode(file.filename)}"';
    }
    header = '$header\r\n'
        'content-type: ${file.contentType}';
    return '$header\r\n\r\n';
  }

  /// Encode [value] in the same way browsers do.
  String _browserEncode(String value) {
    // http://tools.ietf.org/html/rfc2388 mandates some complex encodings for
    // field names and file names, but in practice user agents seem not to
    // follow this at all. Instead, they URL-encode `\r`, `\n`, and `\r\n` as
    // `\r\n`; URL-encode `"`; and do nothing else (even for `%` or non-ASCII
    // characters). We follow their behavior.
    return value.replaceAll(_newlineRegExp, '%0D%0A').replaceAll('"', '%22');
  }

  /// The total length of the request body, in bytes. This is calculated from
  /// [fields] and [files] and cannot be set manually.
  int get length {
    var length = 0;

    all_fields.forEach((entry) {
      if (entry.key["is_file"] == true) {
        var file = entry.value;
        length += '--'.length +
            _BOUNDARY_LENGTH +
            '\r\n'.length +
            utf8
                .encode(_headerForFile(MapEntry(entry.key["key"], file)))
                .length +
            file.length +
            '\r\n'.length;
      } else {
        length += '--'.length +
            _BOUNDARY_LENGTH +
            '\r\n'.length +
            utf8
                .encode(_headerForField(entry.key["key"], entry.value))
                .length +
            utf8
                .encode(entry.value)
                .length +
            '\r\n'.length;
      }
    });
    return length + '--'.length + _BOUNDARY_LENGTH + '--\r\n'.length;
  }

  Stream<List<int>> finalize() {
    if (isFinalized) {
      throw StateError("Can't finalize a finalized MultipartFile.");
    }
    _isFinalized = true;
    var controller = StreamController<List<int>>(sync: false);
    void writeAscii(String string) {
      controller.add(utf8.encode(string));
    }

    void writeUtf8(String string) => controller.add(utf8.encode(string));
    void writeLine() => controller.add([13, 10]); // \r\n
    var write_controller = StreamController<String>(sync: false);
    var field_complete = false;
    var file_complete = false;
    write_controller.stream.listen((data) {
      if (data == 'file') {
        file_complete = true;
      } else if (data == 'field') {
        field_complete = true;
      }
      if (field_complete == true && file_complete == true) {
        if (files.length == 0) {
          writeAscii('--$boundary--\r\n');
        }
//        controller.close();
      }
    });
    var file_length = 0;
    var boundary_controller = StreamController<int>();
    var index = 0;
    Future.forEach(all_fields, ((entry) async {
      index += 1;
      if (entry.key["is_file"] == true) {
        var file = entry.value;
        file_length += 1;
        writeAscii('--$boundary\r\n');
        writeAscii(_headerForFile(MapEntry(entry.key["key"], file)));
        var yes = await writeStreamToSink(
            file.finalize(), controller, file_length, files.length);
        writeLine();
        boundary_controller.add(index);
      } else {
        writeAscii('--$boundary\r\n');
        writeAscii(_headerForField(entry.key["key"], entry.value));
        writeUtf8(entry.value);
        writeLine();
        boundary_controller.add(index);
      }
    }));


    boundary_controller.stream.listen((index) {
      if (index == all_fields.length) {
        writeAscii('--$boundary--\r\n');
        controller.close();
      }
    });
    return controller.stream;
  }

  ///Transform the entire FormData contents as a list of bytes asynchronously.
  Future<List<int>> readAsBytes() {
    return Future(() => finalize().reduce((a, b) => [...a, ...b]));
  }
}
