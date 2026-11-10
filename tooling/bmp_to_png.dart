// 把 capture_screen.dart 产出的 32 位 BMP 转成 PNG，供走查截图查看 / 交付。
//
// 为什么自己写：本机 PowerShell 的 `Add-Type -AssemblyName System.Drawing`
// 被安全策略拦截，也没有 ImageMagick；而截图工具是纯 Dart Win32 GDI，
// 直接把 BGRA 像素重排成 PNG 的 RGBA 扫描线最省事、跨平台可复现。
//
// 运行：dart run tooling/bmp_to_png.dart <in.bmp> <out.png>
import 'dart:io';
import 'dart:typed_data';

const List<int> _pngSignature = <int>[137, 80, 78, 71, 13, 10, 26, 10];

int _crc32(List<int> data) {
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc ^= b;
    for (var i = 0; i < 8; i++) {
      crc = (crc >>> 1) ^ ((crc & 1) != 0 ? 0xEDB88320 : 0);
    }
  }
  return crc ^ 0xFFFFFFFF;
}

Uint8List _u32be(int value) =>
    (ByteData(4)..setUint32(0, value, Endian.big)).buffer.asUint8List();

Uint8List _chunk(String type, List<int> data) {
  final typeBytes = Uint8List.fromList(type.codeUnits);
  final bytes = BytesBuilder()
    ..add(_u32be(data.length))
    ..add(typeBytes)
    ..add(data)
    ..add(_u32be(_crc32(<int>[...typeBytes, ...data])));
  return bytes.takeBytes();
}

Uint8List _ihdr(int width, int height) {
  final bd = ByteData(13)
    ..setUint32(0, width, Endian.big)
    ..setUint32(4, height, Endian.big)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6) // color type: RGBA
    ..setUint8(10, 0) // compression
    ..setUint8(11, 0) // filter
    ..setUint8(12, 0); // interlace
  return bd.buffer.asUint8List();
}

/// 可选裁剪参数 `--crop=x,y,w,h[,scale]`：走查时把屏幕边缘放大看，
/// 用来确认「默认状态下没有任何伸缩控件」这种细节。
({int x, int y, int w, int h, int scale})? _cropOf(String? arg) {
  if (arg == null) return null;
  if (!arg.startsWith('--crop=')) {
    stderr.writeln('第三个参数必须是 --crop=x,y,w,h[,scale]');
    exit(2);
  }
  final parts = arg.substring('--crop='.length).split(',');
  if (parts.length != 4 && parts.length != 5) {
    stderr.writeln('裁剪参数格式：--crop=x,y,w,h[,scale]');
    exit(2);
  }
  final nums = parts.map(int.tryParse).toList();
  if (nums.any((v) => v == null)) {
    stderr.writeln('裁剪参数必须是整数');
    exit(2);
  }
  final scale = parts.length == 5 ? nums[4]! : 1;
  if (nums[0]! < 0 ||
      nums[1]! < 0 ||
      nums[2]! <= 0 ||
      nums[3]! <= 0 ||
      scale < 1 ||
      scale > 8) {
    stderr.writeln('裁剪范围或放大倍数不合法（scale 限 1..8）');
    exit(2);
  }
  return (x: nums[0]!, y: nums[1]!, w: nums[2]!, h: nums[3]!, scale: scale);
}

void main(List<String> args) {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln('用法：dart run tooling/bmp_to_png.dart <in.bmp> <out.png> '
        '[--crop=x,y,w,h[,scale]]');
    exit(2);
  }
  final crop = _cropOf(args.length == 3 ? args[2] : null);
  final src = File(args[0]).readAsBytesSync();
  if (src.length < 54 || src[0] != 0x42 || src[1] != 0x4D) {
    stderr.writeln('输入不是 BMP 文件');
    exit(1);
  }
  final bd = ByteData.sublistView(src);
  final offset = bd.getUint32(10, Endian.little);
  final width = bd.getInt32(18, Endian.little);
  final signedHeight = bd.getInt32(22, Endian.little);
  final topDown = signedHeight < 0;
  final height = signedHeight.abs();
  final bpp = bd.getUint16(28, Endian.little);
  if (bpp != 32 || width <= 0 || height <= 0) {
    stderr.writeln('只支持 32 位 BGRA BMP，实际 bpp=$bpp ${width}x$height');
    exit(1);
  }
  final rowBytes = width * 4;
  if (offset + rowBytes * height > src.length) {
    stderr.writeln('BMP 像素数据不完整');
    exit(1);
  }

  if (crop != null &&
      (crop.x + crop.w > width || crop.y + crop.h > height)) {
    stderr.writeln('裁剪范围超出原图 ${width}x$height');
    exit(1);
  }
  final outWidth = crop == null ? width : crop.w * crop.scale;
  final outHeight = crop == null ? height : crop.h * crop.scale;
  final outRowBytes = outWidth * 4;

  // PNG 每行第一个字节是 filter type（0 = None），其后是 RGBA。
  final raw = Uint8List((outRowBytes + 1) * outHeight);
  for (var oy = 0; oy < outHeight; oy++) {
    final dstOff = oy * (outRowBytes + 1);
    raw[dstOff] = 0;
    for (var ox = 0; ox < outWidth; ox++) {
      final x = crop == null ? ox : crop.x + ox ~/ crop.scale;
      final y = crop == null ? oy : crop.y + oy ~/ crop.scale;
      final srcY = topDown ? y : height - 1 - y;
      final i = offset + srcY * rowBytes + x * 4;
      final j = dstOff + 1 + ox * 4;
      raw[j] = src[i + 2]; // B -> R
      raw[j + 1] = src[i + 1]; // G
      raw[j + 2] = src[i]; // R -> B
      // GetDIBits 的 BI_RGB 32 位不填 alpha，必须强制 255，否则整图透明。
      raw[j + 3] = 255;
    }
  }

  final png = BytesBuilder()
    ..add(_pngSignature)
    ..add(_chunk('IHDR', _ihdr(outWidth, outHeight)))
    ..add(_chunk('IDAT', ZLibCodec(level: 6).encode(raw)))
    ..add(_chunk('IEND', const <int>[]));
  final out = File(args[1]);
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(png.takeBytes());
  print('PNG 已保存：${out.path}（${outWidth}x$outHeight）');
}
