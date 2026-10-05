import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';

void main() {
  runApp(const FlashDriveValidatorApp());
}

class FlashDriveValidatorApp extends StatelessWidget {
  const FlashDriveValidatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flash Drive Validator',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: Colors.deepPurple,
        colorScheme: const ColorScheme.dark(
          primary: Colors.deepPurpleAccent,
          secondary: Colors.purpleAccent,
        ),
      ),
      home: const ValidatorScreen(),
    );
  }
}

enum BlockStatus { untested, writing, verifying, good, warning, bad }

class ValidatorScreen extends StatefulWidget {
  const ValidatorScreen({super.key});

  @override
  State<ValidatorScreen> createState() => _ValidatorScreenState();
}

class _ValidatorScreenState extends State<ValidatorScreen> {
  static const int totalBlocks = 120;
  
  List<BlockStatus> blocks = List.filled(totalBlocks, BlockStatus.untested);
  bool isTesting = false;
  String? selectedPath;

  int declaredGb = 8; // Значение по умолчанию, пока не выбрана флешка
  
  double targetMb = 0.0;
  double writtenMb = 0.0;
  double realMb = 0.0;
  int blocksDone = 0;

  Future<void> pickDrive() async {
    String? path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Выберите папку на USB',
    );
    if (path != null) {
      setState(() {
        selectedPath = path;
      });
      // Как только выбрали путь - запускаем автоопределение размера
      await _autoDetectSize(path);
    }
  }

  // Округляет сырой размер в ГБ до стандартных значений флешек
  int _roundToStandardGb(double rawGb) {
    List<int> standards = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048];
    int bestMatch = 8;
    double minDiff = double.infinity;
    for (int s in standards) {
      double diff = (s - rawGb).abs();
      if (diff < minDiff) {
        minDiff = diff;
        bestMatch = s;
      }
    }
    return bestMatch;
  }

  // Спрашивает у системы Linux (Android) реальный заявленный объем диска
  Future<void> _autoDetectSize(String path) async {
    try {
      final result = await Process.run('df', ['-k', path]);
      final output = result.stdout.toString();
      final lines = output.trim().split('\n');
      
      if (lines.length > 1) {
        final parts = lines[1].trim().split(RegExp(r'\s+'));
        // Ищем первый столбец, состоящий только из цифр (это блоки по 1 КБ)
        for (int i = 1; i < parts.length; i++) {
          if (RegExp(r'^\d+$').hasMatch(parts[i])) {
            int kBlocks = int.parse(parts[i]);
            // Производители флешек считают 1 ГБ = 1,000,000,000 байт
            double rawGb = (kBlocks * 1024) / 1000000000;
            int detected = _roundToStandardGb(rawGb);
            
            setState(() {
              // Если определилось стандартное значение, обновляем дропдаун
              if ([4, 8, 16, 32, 64, 128, 256, 512, 1024].contains(detected)) {
                declaredGb = detected;
              }
            });
            
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Автоопределение: ${rawGb.toStringAsFixed(1)} ГБ\nУстановлен профиль: $declaredGb ГБ'),
                  backgroundColor: Colors.green.shade800,
                  duration: const Duration(seconds: 4),
                )
              );
            }
            break;
          }
        }
      }
    } catch (e) {
      // Если системная команда не сработала, ничего не делаем - пользователь выберет сам
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось автоопределить размер. Выберите вручную.'),
            backgroundColor: Colors.redAccent,
          )
        );
      }
    }
  }

  String formatSize(double mb) {
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(2)} ГБ';
    }
    return '${mb.toStringAsFixed(0)} МБ';
  }

  Future<bool> _verifyFile(File file, int expectedSize, Uint8List pattern, {bool quick = false}) async {
    try {
      if (!await file.exists()) return false;
      var fileStream = file.openRead();
      int bytesReadTotal = 0;
      
      await for (var chunk in fileStream) {
        for (int j = 0; j < chunk.length; j += 4096) {
          int expectedPatternIndex = (bytesReadTotal + j) % pattern.length;
          if (chunk[j] != pattern[expectedPatternIndex]) return false;
        }
        bytesReadTotal += chunk.length;
        if (quick) break; 
      }
      if (!quick && bytesReadTotal != expectedSize) return false;
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> cleanupFiles() async {
    for (int i = 0; i < totalBlocks; i++) {
      try {
        File f = File('$selectedPath/valitest_block_$i.bin');
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  Future<void> startTest() async {
    if (selectedPath == null && !mounted) return;
    
    double rawBytes = (declaredGb * 1000.0 * 1000.0 * 1000.0) - (100.0 * 1024.0 * 1024.0);
    if (rawBytes <= 0) rawBytes = 100 * 1024 * 1024;
    int blockSizeBytes = (rawBytes / totalBlocks).floor();

    setState(() {
      isTesting = true;
      blocks = List.filled(totalBlocks, BlockStatus.untested);
      targetMb = (totalBlocks * blockSizeBytes) / (1024 * 1024);
      writtenMb = 0.0;
      realMb = 0.0;
      blocksDone = 0;
    });

    final int chunkSizeBytes = 4 * 1024 * 1024;
    final Uint8List chunkPattern = Uint8List(chunkSizeBytes);
    for (int i = 0; i < chunkSizeBytes; i++) {
      chunkPattern[i] = i % 256;
    }

    bool isFakeDetected = false;

    for (int i = 0; i < totalBlocks; i++) {
      if (!isTesting) break;

      if (isFakeDetected) {
        setState(() {
          blocks[i] = BlockStatus.bad;
          blocksDone++;
        });
        continue;
      }

      setState(() => blocks[i] = BlockStatus.writing);
      File currentFile = File('$selectedPath/valitest_block_$i.bin');

      bool writeSuccess = true;
      try {
        var sink = currentFile.openWrite();
        int bytesWritten = 0;
        while (bytesWritten < blockSizeBytes) {
          if (!isTesting) { await sink.close(); break; }
          int toWrite = (blockSizeBytes - bytesWritten < chunkSizeBytes) ? blockSizeBytes - bytesWritten : chunkSizeBytes;
          sink.add(Uint8List.view(chunkPattern.buffer, 0, toWrite));
          bytesWritten += toWrite;
        }
        await sink.flush();
        await sink.close();
      } catch (e) {
        writeSuccess = false;
      }

      if (!writeSuccess) {
        setState(() { blocks[i] = BlockStatus.bad; blocksDone++; });
        continue;
      }

      setState(() {
        writtenMb += (blockSizeBytes / (1024 * 1024));
        blocks[i] = BlockStatus.verifying;
      });

      bool isGood = await _verifyFile(currentFile, blockSizeBytes, chunkPattern);

      bool anchorIntact = true;
      if (i > 0) {
        File anchorFile = File('$selectedPath/valitest_block_0.bin');
        anchorIntact = await _verifyFile(anchorFile, blockSizeBytes, chunkPattern, quick: true);
      }

      if (!anchorIntact) {
        isFakeDetected = true;
        setState(() {
          blocks[i] = BlockStatus.bad;
          blocksDone++;
        });
        continue; 
      }

      setState(() {
        if (isGood) {
          realMb += (blockSizeBytes / (1024 * 1024));
          blocks[i] = BlockStatus.good;
        } else {
          blocks[i] = BlockStatus.bad;
        }
        blocksDone++;
      });
    }

    await cleanupFiles();
    setState(() => isTesting = false);
  }

  void stopTest() async {
    setState(() => isTesting = false);
    await cleanupFiles();
  }

  Color getBlockColor(BlockStatus status) {
    switch (status) {
      case BlockStatus.untested: return Colors.grey.shade800;
      case BlockStatus.writing: return Colors.blueAccent;
      case BlockStatus.verifying: return Colors.yellowAccent;
      case BlockStatus.good: return Colors.green.shade600;
      case BlockStatus.warning: return Colors.orangeAccent;
      case BlockStatus.bad: return Colors.redAccent;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flash Drive Validator', style: TextStyle(color: Colors.white)),
        backgroundColor: Colors.black45,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.usb, color: Colors.white),
                    label: Text(
                      selectedPath != null ? 'Выбрано' : 'Выбрать USB',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                      maxLines: 1,
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: selectedPath != null ? Colors.green.shade800 : Colors.deepPurple,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: isTesting ? null : pickDrive,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: isTesting ? Colors.grey.shade800 : Colors.deepPurple.shade900,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: declaredGb,
                      dropdownColor: Colors.grey.shade900,
                      icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      items: [4, 8, 16, 32, 64, 128, 256, 512, 1024]
                          .map((e) => DropdownMenuItem(value: e, child: Text('$e ГБ')))
                          .toList(),
                      onChanged: isTesting ? null : (val) {
                        if (val != null) setState(() => declaredGb = val);
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: Icon(isTesting ? Icons.stop : Icons.play_arrow, color: Colors.white),
                    label: Text(
                      isTesting ? 'Остановка' : 'Старт',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isTesting ? Colors.redAccent : Colors.deepPurpleAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    onPressed: (selectedPath == null) ? null : (isTesting ? stopTest : startTest),
                  ),
                ),
              ],
            ),
            if (selectedPath != null) ...[
              const SizedBox(height: 8),
              Text(
                'Путь: $selectedPath',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              alignment: WrapAlignment.center,
              children: [
                _buildLegendItem(Colors.green.shade600, 'Рабочий'),
                _buildLegendItem(Colors.redAccent, 'Битый/Фейк'),
                _buildLegendItem(Colors.blueAccent, 'Пишем'),
                _buildLegendItem(Colors.yellowAccent, 'Сверка'),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 10,
                  crossAxisSpacing: 3,
                  mainAxisSpacing: 3,
                ),
                itemCount: totalBlocks,
                itemBuilder: (context, index) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    decoration: BoxDecoration(
                      color: getBlockColor(blocks[index]),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: Colors.black45, width: 1),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade900,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Цель: ${formatSize(targetMb)}', style: const TextStyle(color: Colors.grey, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text('Записано: ${formatSize(writtenMb)}', style: const TextStyle(color: Colors.blueAccent, fontSize: 14, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      Text('Реально: ${formatSize(realMb)}', style: const TextStyle(color: Colors.greenAccent, fontSize: 14, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text('Проверено блоков', style: TextStyle(color: Colors.grey, fontSize: 12)),
                      Text(
                        '$blocksDone / $totalBlocks',
                        style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}
