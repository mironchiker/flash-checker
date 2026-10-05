import 'dart:async';
import 'dart:io';
import 'dart:math';
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

// Статусы наших блоков (квадратиков)
enum BlockStatus { untested, writing, verifying, good, warning, bad }

class ValidatorScreen extends StatefulWidget {
  const ValidatorScreen({super.key});

  @override
  State<ValidatorScreen> createState() => _ValidatorScreenState();
}

class _ValidatorScreenState extends State<ValidatorScreen> {
  static const int totalBlocks = 120; // Количество квадратиков на экране
  List<BlockStatus> blocks = List.filled(totalBlocks, BlockStatus.untested);
  bool isTesting = false;
  String? selectedPath;

  // Выбор флешки через Storage Access Framework
  Future<void> pickDrive() async {
    String? path = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Выберите папку на USB-накопителе',
    );
    if (path != null) {
      setState(() {
        selectedPath = path;
      });
    }
  }

  // Основной цикл тестирования
  Future<void> startTest() async {
    if (selectedPath == null && !mounted) return;
    
    setState(() {
      isTesting = true;
      blocks = List.filled(totalBlocks, BlockStatus.untested);
    });

    // Здесь должна быть логика расчета свободного места и деления его на chunks.
    // В данном примере - визуальная симуляция работы алгоритма.
    for (int i = 0; i < totalBlocks; i++) {
      if (!isTesting) break; // Возможность отмены

      // Шаг 1: Запись
      setState(() => blocks[i] = BlockStatus.writing);
      await Future.delayed(const Duration(milliseconds: 50)); // Имитация записи файла
      
      // РЕАЛЬНАЯ ЛОГИКА (закомментирована):
      // File testFile = File('$selectedPath/test_block_$i.bin');
      // await testFile.writeAsBytes(generateRandomData(chunkSize));

      // Шаг 2: Проверка
      setState(() => blocks[i] = BlockStatus.verifying);
      await Future.delayed(const Duration(milliseconds: 50)); // Имитация чтения
      
      // Имитация случайного битого блока (для наглядности)
      final rand = Random().nextInt(100);
      BlockStatus resultStatus = BlockStatus.good;
      if (rand > 95) {
        resultStatus = BlockStatus.bad; // Фейковый объем или битая память
      } else if (rand > 85) {
        resultStatus = BlockStatus.warning; // Медленная скорость чтения/записи
      }

      setState(() => blocks[i] = resultStatus);
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

  // Настройка цветов для состояний
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
        title: const Text('Flash Drive Validator'),
        backgroundColor: Colors.black45,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Панель управления
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.usb),
                    label: Text(selectedPath != null ? 'Выбрано' : 'Выбрать USB'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: selectedPath != null ? Colors.green.shade800 : Colors.deepPurple,
                    ),
                    onPressed: isTesting ? null : pickDrive,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: Icon(isTesting ? Icons.stop : Icons.play_arrow),
                    label: Text(isTesting ? 'Остановить' : 'Старт теста'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isTesting ? Colors.redAccent : Colors.deepPurpleAccent,
                    ),
                    onPressed: (selectedPath == null) 
                        ? null 
                        : (isTesting ? stopTest : startTest),
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
            const SizedBox(height: 24),
            
            // Легенда (Цвета)
            Wrap(
              spacing: 12,
              children: [
                _buildLegendItem(Colors.green.shade600, 'Рабочий'),
                _buildLegendItem(Colors.redAccent, 'Битый/Фейк'),
                _buildLegendItem(Colors.orangeAccent, 'Медленный'),
                _buildLegendItem(Colors.blueAccent, 'Запись'),
                _buildLegendItem(Colors.yellowAccent, 'Сверка'),
              ],
            ),
            const SizedBox(height: 24),

            // Сетка блоков (Map)
            Expanded(
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 10, // 10 квадратиков в ряд
                  crossAxisSpacing: 4,
                  mainAxisSpacing: 4,
                ),
                itemCount: totalBlocks,
                itemBuilder: (context, index) {
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    decoration: BoxDecoration(
                      color: getBlockColor(blocks[index]),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Colors.black26,
                        width: 1,
                      ),
                    ),
                  );
                },
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
        Container(width: 12, height: 12, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
