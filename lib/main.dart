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

enum BlockStatus { untested, writing, written, verifying, good, warning, bad }

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

  int declaredGb = 32; // Выбранный пользователем объем по умолчанию
  
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
    }
  }

  String formatSize(double mb) {
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(2)} ГБ';
    }
    return '${mb.toStringAsFixed(0)} МБ';
  }

  Future<void> startTest() async {
    if (selectedPath == null && !mounted) return;
    
    // Производители флешек считают 1 ГБ = 1,000,000,000 байт.
    // Вычитаем 100 МБ (100 * 1024 * 1024) на файловую систему и погрешности.
    double rawBytes = (declaredGb * 1000.0 * 1000.0 * 1000.0) - (100.0 * 1024.0 * 1024.0);
    if (rawBytes <= 0) rawBytes = 100 * 1024 * 1024; // Защита

    int blockSizeBytes = (rawBytes / totalBlocks).floor();

    setState(() {
      isTesting = true;
      blocks = List.filled(totalBlocks, BlockStatus.untested);
      targetMb = (totalBlocks * blockSizeBytes) / (1024 * 1024);
      writtenMb = 0.0;
      realMb = 0.0;
      blocksDone = 0;
    });

    // Генерируем 4 МБ тестовый паттерн для экономии ОЗУ телефона
    final int chunkSizeBytes = 4 * 1024 * 1024;
    final Uint8List chunkPattern = Uint8List(chunkSizeBytes);
    for (int i = 0; i < chunkSizeBytes; i++) {
      chunkPattern[i] = i % 256;
    }

    // ФАЗА 1: ЗАПИСЬ
    for (int i = 0; i < totalBlocks; i++) {
      if (!isTesting) break;
      setState(() => blocks[i] = BlockStatus.writing);

      File file = File('$selectedPath/valitest_block_$i.bin');
      try {
        var sink = file.openWrite();
        int bytesWritten = 0;
        
        // Пишем файл кусками по 4 МБ, пока не заполним нужный объем кубика
        while (bytesWritten < blockSizeBytes) {
          if (!isTesting) {
            await sink.close();
            break;
          }
          int toWrite = (blockSizeBytes - bytesWritten < chunkSizeBytes) 
              ? blockSizeBytes - bytesWritten 
              : chunkSizeBytes;
              
          sink.add(Uint8List.view(chunkPattern.buffer, 0, toWrite));
          bytesWritten += toWrite;
        }
        
        await sink.flush();
        await sink.close();

        setState(() {
          blocks[i] = BlockStatus.written;
          writtenMb += (blockSizeBytes / (1024 * 1024));
        });
      } catch (e) {
        // Ошибка записи (вытащили флешку или кончилось реальное место)
        setState(() => blocks[i] = BlockStatus.bad);
      }
    }

    // ФАЗА 2: СВЕРКА
    for (int i = 0; i < totalBlocks; i++) {
      if (!isTesting) break;
      if (blocks[i] == BlockStatus.bad) continue; 

      setState(() => blocks[i] = BlockStatus.verifying);

      File file = File('$selectedPath/valitest_block_$i.bin');
      bool isGood = true;
      bool isSlow = false;
      Stopwatch stopwatch = Stopwatch()..start();

      try {
        if (await file.exists()) {
          var fileStream = file.openRead();
          int bytesReadTotal = 0;

          await for (var chunk in fileStream) {
            if (!isTesting) break;
            
            // Быстрая проверка каждого 4096-го байта, чтобы не вешать процессор
            for (int j = 0; j < chunk.length; j += 4096) {
              int expectedPatternIndex = (bytesReadTotal + j) % chunkSizeBytes;
              if (chunk[j] != chunkPattern[expectedPatternIndex]) {
                isGood = false;
                break;
              }
            }
            bytesReadTotal += chunk.length;
            if (!isGood) break;
          }

          if (bytesReadTotal != blockSizeBytes) {
            isGood = false;
          }
        } else {
          isGood = false;
        }
      } catch (e) {
        isGood = false;
      }
      
      stopwatch.stop();
      // Если файл читался дольше 3 секунд — блок медленный
      if (stopwatch.elapsedMilliseconds > 3000) {
        isSlow = true; 
      }

      setState(() {
        if (isGood) {
          realMb += (blockSizeBytes / (1024 * 1024));
          blocks[i] = isSlow ? BlockStatus.warning : BlockStatus.good;
        } else {
          blocks[i] = BlockStatus.bad;
        }
        blocksDone++;
      });

      // Зачищаем файл за собой
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    setState(() {
      isTesting = false;
    });
  }

  void stopTest() {
    setState(() {
      isTesting = false;
    });
  }

  Color getBlockColor(BlockStatus status) {
    switch (status) {
      case BlockStatus.untested: return Colors.grey.shade800;
      case BlockStatus.writing: return Colors.blueAccent;
      case BlockStatus.written: return Colors.blueGrey;
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
                // Выпадающий список выбора объема
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
                      items: [4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048]
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
                      isTesting ? 'Остановить' : 'Старт',
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
                _buildLegendItem(Colors.redAccent, 'Битый'),
                _buildLegendItem(Colors.orangeAccent, 'Медленный'),
                _buildLegendItem(Colors.blueAccent, 'Пишем'),
                _buildLegendItem(Colors.blueGrey, 'Записано'),
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
            // Панель статистики
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
