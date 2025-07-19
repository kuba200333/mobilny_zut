import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;

// Uruchomienie aplikacji Flutter
void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Oceny z E-Dziekanatu',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        useMaterial3: true,
        fontFamily: 'Roboto',
        cardTheme: CardThemeData(
          elevation: 2,
          margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      home: const GradesPage(),
    );
  }
}

// --- Modele danych ---

/// Przechowuje informacje o ocenach z jednego przedmiotu.
class Grade {
  final String subject;
  final String type;
  final String lecturer;
  final String hours;
  final String term1; // Przechowujemy jako HTML
  final String retake1;
  final String retake2;
  final String ects;

  // Zmienione pola do przechowywania osobno oceny i daty
  final String gradeValue;
  final String gradeDate;

  Grade({
    required this.subject,
    required this.type,
    required this.lecturer,
    required this.hours,
    required this.term1,
    required this.retake1,
    required this.retake2,
    required this.ects,
    // Konstruktor od razu parsuje dane
  })  : gradeValue = _extractGradeAndDate(term1).grade,
        gradeDate = _extractGradeAndDate(term1).date;

  // Nowa funkcja do rozdzielania oceny i daty z HTML
  static ({String grade, String date}) _extractGradeAndDate(String html) {
    if (!html.contains('<br>')) {
      // Jeśli nie ma znacznika <br>, zwracamy sam tekst jako ocenę
      final document = parser.parseFragment(html);
      return (grade: document.text?.trim() ?? html, date: '');
    }

    // Dzielimy HTML po znaczniku <br>
    final parts = html.split('<br>');
    final gradeDoc = parser.parseFragment(parts.first);
    final grade = gradeDoc.text?.trim() ?? '';
    final date = parts.length > 1 ? parts.last.trim() : '';

    return (grade: grade, date: date);
  }
}

/// Przechowuje informacje o bieżącym semestrze i nawigacji.
class SemesterInfo {
  final String name;
  final bool hasPrevious;
  final bool hasNext;

  SemesterInfo({required this.name, this.hasPrevious = false, this.hasNext = false});
}

// --- Serwis do komunikacji z e-dziekanatem ---

class EDeaneryService {
  final Dio _dio;
  final CookieJar _cookieJar = CookieJar();
  static const String _baseUrl = 'https://edziekanat.zut.edu.pl/WU/';

  EDeaneryService() : _dio = Dio() {
    _dio.interceptors.add(CookieManager(_cookieJar));
    _dio.options.followRedirects = true;
    _dio.options.headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36';
    // Mówimy Dio, aby nie traktował przekierowań (statusy 3xx) jako błędu
    _dio.options.validateStatus = (status) {
      return status != null && status >= 200 && status < 400;
    };
  }

  /// Główna funkcja pobierająca oceny, wzorowana na skrypcie PHP.
  Future<Map<String, dynamic>> getGrades(String login, String password, int semesterOffset) async {
    const String gradesPageUrl = "${_baseUrl}OcenyP.aspx";
    String htmlContent;

    // 1. Sprawdzenie, czy sesja jest aktywna.
    // Jeśli nie, wykonujemy logowanie.
    Response response = await _dio.get(gradesPageUrl);
    htmlContent = response.data;

    if (htmlContent.contains('txtIdent')) { // Identyfikator pola login
      htmlContent = await _login(login, password);
    }
    
    // 2. Nawigacja po semestrach, jeśli jest to wymagane.
    if (semesterOffset != 0) {
       htmlContent = await _navigateSemesters(htmlContent, semesterOffset);
    }

    // 3. Parsowanie finalnej strony z ocenami.
    return _parseGradesPage(htmlContent);
  }

  /// Wykonuje proces logowania.
  Future<String> _login(String login, String password) async {
    const String loginPageUrl = "${_baseUrl}PodzGodzin.aspx";
    Response response = await _dio.get(loginPageUrl);
    
    dom.Document document = parser.parse(response.data);
    String formAction = document.querySelector('form')?.attributes['action'] ?? '';
    final String fullActionUrl = _baseUrl + formAction;

    Map<String, String> postData = {};
    document.querySelectorAll('input[type="hidden"]').forEach((input) {
      postData[input.attributes['name']!] = input.attributes['value'] ?? '';
    });

    postData.addAll({
      'ctl00\$ctl00\$ContentPlaceHolder\$MiddleContentPlaceHolder\$txtIdent': login,
      'ctl00\$ctl00\$ContentPlaceHolder\$MiddleContentPlaceHolder\$txtHaslo': password,
      'ctl00\$ctl00\$ContentPlaceHolder\$MiddleContentPlaceHolder\$butLoguj': 'Zaloguj',
    });

    Response loginResponse = await _dio.post(
      fullActionUrl,
      data: FormData.fromMap(postData),
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    
    return loginResponse.data;
  }

  /// Wykonuje nawigację "w przód" lub "w tył" o zadaną liczbę semestrów.
  Future<String> _navigateSemesters(String currentHtml, int offset) async {
    const String gradesPageUrl = "${_baseUrl}OcenyP.aspx";
    String direction = offset > 0 ? 'Następny' : 'Poprzedni';
    String html = currentHtml;

    for (int i = 0; i < offset.abs(); i++) {
        dom.Document doc = parser.parse(html);
        dom.Element? navButton = doc.querySelector("input[value='$direction']");
        if (navButton == null) break; // Przerwij, jeśli nie ma już przycisku

        Map<String, String> postData = {};
        doc.querySelectorAll('input[type="hidden"]').forEach((input) {
            postData[input.attributes['name']!] = input.attributes['value'] ?? '';
        });
        postData[navButton.attributes['name']!] = direction;

        Response navResponse = await _dio.post(
          gradesPageUrl,
          data: FormData.fromMap(postData),
          options: Options(contentType: Headers.formUrlEncodedContentType),
        );
        html = navResponse.data;
    }
    return html;
  }
  
  /// Parsuje HTML strony z ocenami i wyodrębnia dane.
  Map<String, dynamic> _parseGradesPage(String htmlContent) {
    dom.Document document = parser.parse(htmlContent);

    // Sprawdzenie, czy logowanie się powiodło
    final loginCheckElement = document.querySelector("#ctl00_ctl00_ContentPlaceHolder_wumasterWhoIsLoggedIn");
    if (loginCheckElement == null || loginCheckElement.text.trim().isEmpty) {
        throw Exception("Błąd logowania lub sesja wygasła. Sprawdź dane i spróbuj ponownie.");
    }
    
    final List<Grade> grades = [];
    final tableRows = document.querySelectorAll("#ctl00_ctl00_ContentPlaceHolder_RightContentPlaceHolder_dgDane tr.gridDane");

    for (var row in tableRows) {
        final cells = row.querySelectorAll("td");
        if (cells.length > 10) {
            grades.add(Grade(
              subject: cells[0].text.trim(),
              type: cells[1].text.trim(),
              lecturer: cells[3].text.trim(),
              hours: cells[4].text.trim(),
              term1: cells[5].innerHtml,
              retake1: cells[6].innerHtml,
              retake2: cells[7].innerHtml,
              ects: cells[10].text.trim(),
            ));
        }
    }

    final semesterInfo = SemesterInfo(
        name: document.querySelector("span[id*='lblSemestr']")?.text.trim() ?? 'Nieznany semestr',
        hasPrevious: document.querySelector("input[value='Poprzedni']") != null,
        hasNext: document.querySelector("input[value='Następny']") != null,
    );

    return {'grades': grades, 'info': semesterInfo};
  }
}

// --- Główny widget strony ---

class GradesPage extends StatefulWidget {
  const GradesPage({super.key});

  @override
  State<GradesPage> createState() => _GradesPageState();
}

class _GradesPageState extends State<GradesPage> {
  final EDeaneryService _service = EDeaneryService();
  final _loginController = TextEditingController();
  final _passwordController = TextEditingController();

  // Stan UI
  bool _isLoggedIn = false;
  bool _isLoading = false;
  String? _errorMessage;
  
  // Dane
  List<Grade> _grades = [];
  SemesterInfo? _semesterInfo;
  int _currentOffset = 0;

  Future<void> _fetchGrades({int? newOffset}) async {
    if (_loginController.text.isEmpty || _passwordController.text.isEmpty) {
      setState(() {
        _errorMessage = "Login i hasło nie mogą być puste.";
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
      if (newOffset != null) {
        _currentOffset = newOffset;
      }
    });

    try {
      final result = await _service.getGrades(
        _loginController.text,
        _passwordController.text,
        newOffset ?? 0, // Przy pierwszym logowaniu offset jest 0
      );
      
      setState(() {
        _grades = result['grades'];
        _semesterInfo = result['info'];
        _isLoggedIn = true;
      });

    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst("Exception: ", "");
        _isLoggedIn = false; // Wyloguj w razie błędu
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Twoje Oceny'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: _buildContent(),
        ),
      ),
    );
  }
  
  Widget _buildContent() {
    if (_isLoading) {
      return const CircularProgressIndicator();
    }
    if (!_isLoggedIn) {
      return _buildLoginForm();
    }
    return _buildGradesView();
  }

  Widget _buildLoginForm() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Logowanie do e-dziekanatu', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 20),
            TextField(
              controller: _loginController,
              decoration: const InputDecoration(labelText: 'Numer albumu (login)', border: OutlineInputBorder()),
              keyboardType: TextInputType.text,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: 'Hasło', border: OutlineInputBorder()),
              obscureText: true,
            ),
            const SizedBox(height: 20),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
              ),
            ElevatedButton(
              onPressed: () => _fetchGrades(newOffset: 0),
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              child: const Text('Pobierz oceny'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGradesView() {
    return Column(
      children: [
        _buildSemesterNavigation(),
        const SizedBox(height: 16),
        _grades.isEmpty ?
          const Text('Brak przedmiotów i ocen w tym semestrze.')
          : ListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _grades.length,
              itemBuilder: (context, index) {
                final grade = _grades[index];
                final isFinalGrade = grade.type.toLowerCase().contains('końcowa');
                return Card(
                  color: isFinalGrade ? Colors.indigo.shade50 : null,
                  child: ListTile(
                    title: Text(grade.subject, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text("${grade.type}\nProwadzący: ${grade.lecturer}\nECTS: ${grade.ects}"),
                    isThreeLine: true,
                    // Zaktualizowany widok oceny i daty
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(grade.gradeValue, style: Theme.of(context).textTheme.headlineSmall),
                        if (grade.gradeDate.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2.0),
                            child: Text(grade.gradeDate, style: Theme.of(context).textTheme.bodySmall),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
      ],
    );
  }

  Widget _buildSemesterNavigation() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios),
              onPressed: _semesterInfo?.hasPrevious ?? false
                  ? () => _fetchGrades(newOffset: _currentOffset - 1)
                  : null,
            ),
            Flexible(child: Text(_semesterInfo?.name ?? '', style: const TextStyle(fontWeight: FontWeight.bold), textAlign: TextAlign.center,)),
            IconButton(
              icon: const Icon(Icons.arrow_forward_ios),
              onPressed: _semesterInfo?.hasNext ?? false
                  ? () => _fetchGrades(newOffset: _currentOffset + 1)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}