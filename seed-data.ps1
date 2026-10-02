# ============================================================
# QuizMaster - dummy data seeder
# Seeds through the API gateway so everything is valid (hashed
# passwords, generated UUIDs, cross-service links, quiz snapshots).
#
# Prereq: the stack is running (docker compose up) and reachable at
# the gateway below. Run from PowerShell:
#     ./seed-data.ps1
# Re-runnable: users/categories/tags that already exist are skipped;
# a fresh quiz is created each run.
# ============================================================

param(
    [string]$Gateway     = 'http://localhost:8080/api/v1',
    [string]$PgContainer = 'quizmaster-postgres-1',
    [string]$AdminEmail  = 'admin@quiz.com',
    [string]$Password    = 'Passw0rd!'
)

$ErrorActionPreference = 'Stop'

function Invoke-Api {
    param($Method, $Path, $Body, $Token)
    $headers = @{}
    if ($Token) { $headers['Authorization'] = "Bearer $Token" }
    $params = @{
        Method      = $Method
        Uri         = "$Gateway$Path"
        Headers     = $headers
        ContentType = 'application/json'
    }
    if ($null -ne $Body) { $params['Body'] = ($Body | ConvertTo-Json -Depth 12) }
    return Invoke-RestMethod @params
}

# Unwrap the { success, message, data } envelope when present.
function Get-Data($resp) {
    if ($null -ne $resp -and ($resp.PSObject.Properties.Name -contains 'data') -and $null -ne $resp.data) {
        return $resp.data
    }
    return $resp
}

Write-Host "==> Registering admin ($AdminEmail)..."
try {
    Invoke-Api POST '/auth/register' @{ fullName = 'Admin User'; email = $AdminEmail; password = $Password; role = 'ADMIN' } | Out-Null
} catch { Write-Host "    (already exists or non-fatal, continuing)" }

Write-Host "==> Promoting to ADMIN + clearing stale refresh tokens in auth_db..."
# UPDATE promotes to admin. DELETE clears any token 'register' auto-issued —
# auth-service derives the refresh JWT from (subject + issued-at@second), so a
# login in the same second as register would collide on UNIQUE(token_hash).
docker exec $PgContainer psql -U postgres -d auth_db -c "UPDATE users SET role='ADMIN', is_active=true WHERE email='$AdminEmail'; DELETE FROM refresh_tokens rt USING users u WHERE rt.user_id = u.id AND u.email='$AdminEmail';" | Out-Null
Start-Sleep -Milliseconds 1200

Write-Host "==> Logging in as admin..."
$login = Invoke-Api POST '/auth/login' @{ email = $AdminEmail; password = $Password }
$token = $login.accessToken
if (-not $token) { $token = (Get-Data $login).accessToken }
if (-not $token) { throw "Could not obtain an admin access token. Is the stack up?" }
Write-Host "    token acquired."

# --- Students ---
$students = @(
    @{ fullName = 'Alice Student'; email = 'alice@quiz.com' },
    @{ fullName = 'Bob Student';   email = 'bob@quiz.com' },
    @{ fullName = 'Carol Student'; email = 'carol@quiz.com' },
    @{ fullName = 'Dave Student';  email = 'dave@quiz.com' },
    @{ fullName = 'Eve Student';   email = 'eve@quiz.com' }
)
Write-Host "==> Registering $($students.Count) students..."
foreach ($s in $students) {
    try {
        Invoke-Api POST '/auth/register' @{ fullName = $s.fullName; email = $s.email; password = $Password; role = 'STUDENT' } | Out-Null
        Write-Host "    + $($s.email)"
    } catch { Write-Host "    . $($s.email) (exists)" }
}

# --- Category ---
Write-Host "==> Creating category..."
$catUuid = $null
try {
    $cat = Get-Data (Invoke-Api POST '/admin/categories' @{ name = 'General Knowledge'; slug = 'general-knowledge'; description = 'Seeded sample category' } $token)
    $catUuid = $cat.uuid
} catch { Write-Host "    (category exists or non-fatal - quiz will have no category)" }

# --- Tags ---
Write-Host "==> Creating tags..."
foreach ($t in @('sample', 'demo', 'easy')) {
    try { Invoke-Api POST '/admin/tags' @{ name = $t } $token | Out-Null } catch {}
}

# --- Questions (MCQ_SINGLE) ---
$questions = @(
    @{ q = 'What is 2 + 2?';                opts = @(@{t='3';c=$false}, @{t='4';c=$true},  @{t='5';c=$false}, @{t='22';c=$false}) },
    @{ q = 'Capital of France?';            opts = @(@{t='Berlin';c=$false}, @{t='Paris';c=$true}, @{t='Madrid';c=$false}, @{t='Rome';c=$false}) },
    @{ q = 'Largest planet in our system?'; opts = @(@{t='Earth';c=$false}, @{t='Jupiter';c=$true}, @{t='Mars';c=$false}, @{t='Venus';c=$false}) },
    @{ q = 'H2O is commonly known as?';     opts = @(@{t='Water';c=$true},  @{t='Oxygen';c=$false}, @{t='Salt';c=$false}, @{t='Gold';c=$false}) },
    @{ q = 'Color of a clear daytime sky?'; opts = @(@{t='Green';c=$false}, @{t='Blue';c=$true},  @{t='Red';c=$false}, @{t='Black';c=$false}) }
)
Write-Host "==> Creating $($questions.Count) questions..."
$questionUuids = @()
$n = 0
foreach ($qq in $questions) {
    $n++
    $options = @()
    $o = 0
    foreach ($opt in $qq.opts) { $o++; $options += @{ optionText = $opt.t; optionOrder = $o; isCorrect = $opt.c } }
    $created = Get-Data (Invoke-Api POST '/admin/questions' @{
        questionText  = $qq.q
        questionType  = 'MCQ_SINGLE'
        difficulty    = 'MEDIUM'
        defaultMarks  = 1
        negativeMarks = 0
        options       = $options
    } $token)
    $questionUuids += $created.uuid
    Write-Host "    + Q$n"
}

# --- Quiz ---
Write-Host "==> Creating quiz 'Sample Quiz'..."
$quizBody = @{
    title                 = 'Sample Quiz'
    description           = 'A demo quiz seeded by script'
    quizType              = 'EXAM'
    difficulty            = 'MEDIUM'
    timerMode             = 'GLOBAL'
    timeLimitSeconds      = 600
    gracePeriodSeconds    = 30
    totalMarks            = 5
    passMarks             = 3
    negativeMarkingFactor = 0
    maxAttempts           = 3
    cooldownHours         = 0
    showCorrectAnswers    = $true
}
if ($catUuid) { $quizBody['categoryUuid'] = $catUuid }
$quiz = Get-Data (Invoke-Api POST '/admin/quizzes' $quizBody $token)
$quizUuid = $quiz.uuid

Write-Host "==> Attaching questions to the quiz..."
foreach ($quUuid in $questionUuids) {
    Invoke-Api POST "/admin/quizzes/$quizUuid/questions" @{ questionUuid = $quUuid; marks = 1; negativeMarks = 0 } $token | Out-Null
}

Write-Host "==> Publishing the quiz..."
try { Invoke-Api PATCH "/admin/quizzes/$quizUuid/status" @{ status = 'PUBLISHED' } $token | Out-Null }
catch { Write-Host "    (publish failed: $($_.Exception.Message))" }

# --- Group + members ---
Write-Host "==> Creating group 'Class A' and adding students..."
try {
    $group = Get-Data (Invoke-Api POST '/admin/groups' @{ name = 'Class A'; description = 'Seeded student group' } $token)
    $studentsPage = Get-Data (Invoke-Api GET '/admin/students?page=0&size=50' $null $token)
    $studentUuids = @($studentsPage.content | ForEach-Object { $_.uuid })
    if ($studentUuids.Count -gt 0) {
        Invoke-Api POST "/admin/groups/$($group.uuid)/members" @{ userUuids = $studentUuids } $token | Out-Null
        Write-Host "    added $($studentUuids.Count) students to Class A"
    }
} catch { Write-Host "    (group step skipped: $($_.Exception.Message))" }

Write-Host ""
Write-Host "============================================================"
Write-Host " DONE - seeded data:"
Write-Host "   Admin login    : $AdminEmail  /  $Password"
Write-Host "   Student logins : alice/bob/carol/dave/eve at quiz.com  /  $Password"
Write-Host "   + 1 category, 3 tags, 5 questions, 1 published quiz, 1 group"
Write-Host " Log in as a student to see 'Sample Quiz' and take it."
Write-Host "============================================================"
