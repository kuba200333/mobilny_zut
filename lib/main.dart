import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:html/parser.dart' as parser;
import 'package:html/dom.dart' as dom;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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

class Grade {
  final String subject;
  final String type;
  final String lecturer;
  final String hours;
  final String term1;
  final String retake1;
  final String retake2;
  final String ects;
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
  })  : gradeValue = _extractGradeAndDate(term1).grade,
        gradeDate = _extractGradeAndDate(term1).date;

  static ({String grade, String date}) _extractGradeAndDate(String html) {
    if (!html.contains('<br>')) {
      final document = parser.parseFragment(html);
      return (grade: document.text?.trim() ?? html, date: '');
    }

    final parts = html.split('<br>');
    final gradeDoc = parser.parseFragment(parts.first);
    final grade = gradeDoc.text?.trim() ?? '';

    String date = '';
    if (parts.length > 1) {
      final dateDoc = parser.parseFragment(parts.last);
      date = dateDoc.text?.trim() ?? '';
    }

    return (grade: grade, date: date);
  }
}

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

    _dio.options.validateStatus = (status) {
      return status != null && status >= 200 && status < 400;
    };
  }

  Future<Map<String, dynamic>> getGrades(String login, String password, int semesterOffset) async {
    const String gradesPageUrl = "${_baseUrl}OcenyP.aspx";
    String htmlContent;

    Response response = await _dio.get(gradesPageUrl);
    htmlContent = response.data;

    if (htmlContent.contains('txtIdent')) {
      htmlContent = await _login(login, password);
    }
    
    if (semesterOffset != 0) {
       htmlContent = await _navigateSemesters(htmlContent, semesterOffset);
    }

    return _parseGradesPage(htmlContent);
  }

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

  Future<String> _navigateSemesters(String currentHtml, int offset) async {
    const String gradesPageUrl = "${_baseUrl}OcenyP.aspx";
    String direction = offset > 0 ? 'Następny' : 'Poprzedni';
    String html = currentHtml;

    for (int i = 0; i < offset.abs(); i++) {
        dom.Document doc = parser.parse(html);
        dom.Element? navButton = doc.querySelector("input[value='$direction']");
        if (navButton == null) break;

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
  
  Map<String, dynamic> _parseGradesPage(String htmlContent) {
    dom.Document document = parser.parse(htmlContent);

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

  // Zmienne stanu aplikacji
  bool _isLoggedIn = false;
  bool _isLoading = false;
  String? _errorMessage;
  List<Grade> _grades = [];
  SemesterInfo? _semesterInfo;
  int _currentOffset = 0;
  bool _rememberMe = false;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  /// Wczytuje zapisane preferencje użytkownika przy starcie aplikacji.
  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final rememberMe = prefs.getBool('rememberMe') ?? false;

    setState(() {
      _rememberMe = rememberMe;
    });

    if (_rememberMe) {
      final login = prefs.getString('login');
      final password = prefs.getString('password');
      if (login != null && password != null) {
        _loginController.text = login;
        _passwordController.text = password;
      }
    }
  }

  /// Główna funkcja do pobierania ocen.
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
        newOffset ?? 0,
      );
      
      setState(() {
        _grades = result['grades'];
        _semesterInfo = result['info'];
        _isLoggedIn = true;
      });

      // Po udanym logowaniu zapisz dane (jeśli zaznaczono)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('rememberMe', _rememberMe);
      if (_rememberMe) {
        await prefs.setString('login', _loginController.text);
        await prefs.setString('password', _passwordController.text);
      } else {
        await prefs.remove('login');
        await prefs.remove('password');
      }

    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst("Exception: ", "");
        _isLoggedIn = false;
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  /// Wylogowuje użytkownika, czyszcząc zapisane dane i stan aplikacji.
  Future<void> _logout() async {
  // UWAGA: Celowo nie czyścimy danych z SharedPreferences.
  // Dzięki temu opcja "Zapamiętaj mnie" dalej działa.

  // Resetujemy tylko stan aplikacji, aby wrócić do ekranu logowania.
  setState(() {
    _isLoggedIn = false;
    _isLoading = false;
    _errorMessage = null;
    _grades = [];
    _semesterInfo = null;
    _currentOffset = 0;
    _selectedIndex = 0; // Ustaw domyślną zakładkę na "Oceny"

    // Nie czyścimy kontrolerów (_loginController, _passwordController)
    // ani stanu _rememberMe. Dane w formularzu pozostaną.
  });
}


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedIndex == 0 ? 'Twoje Oceny' : 'Profil'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: <Widget>[
            _buildGradesContent(),
            _buildProfileContent(),
          ][_selectedIndex],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.school),
            label: 'Oceny',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'Profil',
          ),
        ],
        currentIndex: _selectedIndex,
        onTap: (int index) {
          setState(() {
            _selectedIndex = index;
          });
        },
      ),
    );
  }
  
  /// Buduje główną zawartość dla zakładki Oceny
  Widget _buildGradesContent() {
    if (_isLoading) {
      return const CircularProgressIndicator();
    }
    if (!_isLoggedIn) {
      return _buildLoginForm();
    }
    return _buildGradesView();
  }
  
  /// Buduje główną zawartość dla zakładki Profil
  Widget _buildProfileContent() {
    if (_isLoading) {
      return const CircularProgressIndicator();
    }
    if (!_isLoggedIn) {
      return _buildLoginForm();
    }
    
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                const CircleAvatar(
                  radius: 40,
                  child: Icon(Icons.person, size: 40),
                ),
                const SizedBox(height: 16),
                Text(
                  'Zalogowano jako:',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  _loginController.text,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        ElevatedButton.icon(
          icon: const Icon(Icons.logout),
          label: const Text('Wyloguj'),
          onPressed: _logout,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.red.shade400,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      ],
    );
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
            const SizedBox(height: 12),
            if (_errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Text(_errorMessage!, style: const TextStyle(color: Colors.red)),
              ),
            CheckboxListTile(
              title: const Text("Zapamiętaj mnie"),
              value: _rememberMe,
              onChanged: (newValue) {
                setState(() {
                  _rememberMe = newValue ?? false;
                });
              },
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            ),
            const SizedBox(height: 10),
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
        _grades.isEmpty
            ? const Text('Brak przedmiotów i ocen w tym semestrze.')
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
            Flexible(
              child: Text(
                _semesterInfo?.name ?? '',
                style: const TextStyle(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
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