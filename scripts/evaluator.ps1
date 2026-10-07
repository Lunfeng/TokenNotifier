$script:AllowedEvaluatorFields = @(
    'request_count', 'input_tokens', 'output_tokens', 'cache_read_tokens',
    'cache_creation_tokens', 'input_cost_usd', 'output_cost_usd',
    'cache_read_cost_usd', 'cache_creation_cost_usd', 'total_cost_usd',
    'duration_ms_total', 'duration_ms_max', 'first_token_ms_first',
    'model', 'provider_id', 'status_code', 'codex_session_id',
    'codex_turn_id', 'codex_cwd', 'turn_outcome', 'attribution_status',
    'matched_request_count', 'unmatched_request_count', 'thread_name'
)

function Get-AllowedFields {
    return [string[]]$script:AllowedEvaluatorFields
}

function ConvertTo-EvaluatorDecimal([object]$Value) {
    if ($null -eq $Value -or $Value -is [bool]) {
        throw 'Expected a numeric value'
    }
    try { return [decimal]$Value } catch { throw 'Expected a numeric value' }
}

function New-EvaluatorToken([string]$Type, [object]$Value) {
    return [pscustomobject]@{ Type = $Type; Value = $Value }
}

function Get-EvaluatorTokens([string]$Expression) {
    if ([string]::IsNullOrWhiteSpace($Expression)) { throw 'Expression is empty' }
    $tokens = New-Object 'System.Collections.Generic.List[object]'
    $index = 0
    while ($index -lt $Expression.Length) {
        $character = $Expression[$index]
        if ([char]::IsWhiteSpace($character)) { $index = $index + 1; continue }

        if ([char]::IsDigit($character) -or $character -eq '.') {
            $start = $index
            $dots = 0
            while ($index -lt $Expression.Length -and ([char]::IsDigit($Expression[$index]) -or $Expression[$index] -eq '.')) {
                if ($Expression[$index] -eq '.') { $dots = $dots + 1 }
                $index = $index + 1
            }
            $literal = $Expression.Substring($start, $index - $start)
            if ($dots -gt 1 -or $literal -eq '.') { throw 'Invalid number' }
            $number = [decimal]0
            if (-not [decimal]::TryParse($literal, [Globalization.NumberStyles]::AllowDecimalPoint, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
                throw 'Invalid number'
            }
            $tokens.Add((New-EvaluatorToken 'Number' $number))
            continue
        }

        if ([char]::IsLetter($character) -or $character -eq '_') {
            $start = $index
            $index = $index + 1
            while ($index -lt $Expression.Length -and ([char]::IsLetterOrDigit($Expression[$index]) -or $Expression[$index] -eq '_')) { $index = $index + 1 }
            $identifier = $Expression.Substring($start, $index - $start)
            $tokens.Add((New-EvaluatorToken 'Identifier' $identifier))
            continue
        }

        if ($character -eq '(' -or $character -eq ')' -or $character -eq ',') {
            $tokens.Add((New-EvaluatorToken ([string]$character) $character))
            $index = $index + 1
            continue
        }

        $operator = [string]$character
        if ($index + 1 -lt $Expression.Length) {
            $pair = $Expression.Substring($index, 2)
            if ($pair -in @('<=', '>=', '==', '!=')) { $operator = $pair; $index = $index + 1 }
        }
        if ($operator -notin @('+', '-', '*', '/', '<', '<=', '>', '>=', '==', '!=')) { throw 'Unexpected character' }
        $tokens.Add((New-EvaluatorToken 'Operator' $operator))
        $index = $index + 1
    }
    $tokens.Add((New-EvaluatorToken 'EOF' $null))
    return $tokens.ToArray()
}

function Get-EvaluatorCurrent($State) { return $State.Tokens[$State.Index] }

function Move-EvaluatorToken($State) {
    $token = Get-EvaluatorCurrent $State
    $State.Index = $State.Index + 1
    return $token
}

function Assert-EvaluatorToken($State, [string]$Type, [object]$Value) {
    $token = Get-EvaluatorCurrent $State
    if ($token.Type -ne $Type -or ($null -ne $Value -and $token.Value -ne $Value)) { throw 'Invalid syntax' }
    Move-EvaluatorToken $State | Out-Null
}

function Invoke-ParseExpression($State) {
    $left = Invoke-ParseAdditive $State
    $token = Get-EvaluatorCurrent $State
    if ($token.Type -eq 'Operator' -and $token.Value -in @('<', '<=', '>', '>=', '==', '!=')) {
        Move-EvaluatorToken $State | Out-Null
        $right = Invoke-ParseAdditive $State
        $leftNumber = ConvertTo-EvaluatorDecimal $left
        $rightNumber = ConvertTo-EvaluatorDecimal $right
        switch ($token.Value) {
            '<' { return $leftNumber -lt $rightNumber }
            '<=' { return $leftNumber -le $rightNumber }
            '>' { return $leftNumber -gt $rightNumber }
            '>=' { return $leftNumber -ge $rightNumber }
            '==' { return $leftNumber -eq $rightNumber }
            '!=' { return $leftNumber -ne $rightNumber }
        }
    }
    return $left
}

function Invoke-ParseAdditive($State) {
    $value = Invoke-ParseMultiplicative $State
    while ((Get-EvaluatorCurrent $State).Type -eq 'Operator' -and (Get-EvaluatorCurrent $State).Value -in @('+', '-')) {
        $operator = Move-EvaluatorToken $State
        $right = Invoke-ParseMultiplicative $State
        $leftNumber = ConvertTo-EvaluatorDecimal $value
        $rightNumber = ConvertTo-EvaluatorDecimal $right
        if ($operator.Value -eq '+') { $value = $leftNumber + $rightNumber } else { $value = $leftNumber - $rightNumber }
    }
    return $value
}

function Invoke-ParseMultiplicative($State) {
    $value = Invoke-ParseUnary $State
    while ((Get-EvaluatorCurrent $State).Type -eq 'Operator' -and (Get-EvaluatorCurrent $State).Value -in @('*', '/')) {
        $operator = Move-EvaluatorToken $State
        $right = Invoke-ParseUnary $State
        $leftNumber = ConvertTo-EvaluatorDecimal $value
        $rightNumber = ConvertTo-EvaluatorDecimal $right
        if ($operator.Value -eq '/') {
            if ($rightNumber -eq 0) { throw 'Division by zero' }
            $value = $leftNumber / $rightNumber
        } else { $value = $leftNumber * $rightNumber }
    }
    return $value
}

function Invoke-ParseUnary($State) {
    $token = Get-EvaluatorCurrent $State
    if ($token.Type -eq 'Operator' -and $token.Value -in @('+', '-')) {
        Move-EvaluatorToken $State | Out-Null
        $value = ConvertTo-EvaluatorDecimal (Invoke-ParseUnary $State)
        if ($token.Value -eq '-') { return -$value }
        return $value
    }
    return Invoke-ParsePrimary $State
}

function Invoke-ParsePrimary($State) {
    $token = Get-EvaluatorCurrent $State
    if ($token.Type -eq 'Number') { Move-EvaluatorToken $State | Out-Null; return $token.Value }
    if ($token.Type -eq 'Identifier') {
        $name = [string]$token.Value
        Move-EvaluatorToken $State | Out-Null
        if ((Get-EvaluatorCurrent $State).Type -eq '(') { return Invoke-ParseFunction $State $name }
        if (($name -notin $script:AllowedEvaluatorFields) -or (-not ($State.Context.ContainsKey($name)))) { throw "Unknown identifier: $name" }
        return ConvertTo-EvaluatorDecimal $State.Context[$name]
    }
    if ($token.Type -eq '(') {
        Move-EvaluatorToken $State | Out-Null
        $value = Invoke-ParseExpression $State
        Assert-EvaluatorToken $State ')' $null
        return $value
    }
    throw 'Invalid syntax'
}

function Invoke-ParseFunction($State, [string]$Name) {
    if ($Name -notin @('abs', 'max', 'min', 'round')) { throw "Function is not allowed: $Name" }
    Assert-EvaluatorToken $State '(' $null
    $arguments = New-Object 'System.Collections.Generic.List[decimal]'
    if ((Get-EvaluatorCurrent $State).Type -ne ')') {
        while ($true) {
            $arguments.Add((ConvertTo-EvaluatorDecimal (Invoke-ParseExpression $State)))
            if ((Get-EvaluatorCurrent $State).Type -ne ',') { break }
            Move-EvaluatorToken $State | Out-Null
        }
    }
    Assert-EvaluatorToken $State ')' $null
    if ($arguments.Count -eq 0) { throw 'Function requires arguments' }
    switch ($Name) {
        'abs' { if ($arguments.Count -ne 1) { throw 'abs requires one argument' }; return [math]::Abs($arguments[0]) }
        'round' {
            if ($arguments.Count -lt 1 -or $arguments.Count -gt 2) { throw 'round requires one or two arguments' }
            if ($arguments.Count -eq 1) { return [math]::Round($arguments[0]) }
            return [math]::Round($arguments[0], [int]$arguments[1])
        }
        'max' { $result = $arguments[0]; foreach ($item in $arguments) { if ($item -gt $result) { $result = $item } }; return $result }
        'min' { $result = $arguments[0]; foreach ($item in $arguments) { if ($item -lt $result) { $result = $item } }; return $result }
    }
}

function Evaluate-Expression([string]$Expression, [hashtable]$Context) {
    $state = @{ Tokens = @(Get-EvaluatorTokens $Expression); Index = 0; Context = $Context }
    $result = Invoke-ParseExpression $state
    if ((Get-EvaluatorCurrent $state).Type -ne 'EOF') { throw 'Invalid syntax' }
    return $result
}

function Format-DisplayValue([object]$Value, [string]$Format) {
    if ($null -eq $Value) { return '--' }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    switch ($Format) {
        'text' { return [string]$Value }
        'integer' { return ([decimal]$Value).ToString('N0', $culture) }
        'decimal' { return ([decimal]$Value).ToString('0.####', $culture) }
        'currency_usd' { return ([decimal]$Value).ToString('$#,##0.00##', $culture) }
        'percent' { return (([decimal]$Value) * [decimal]100).ToString('0.##', $culture) + '%' }
        'milliseconds' { return ([decimal]$Value).ToString('N0', $culture) + ' ms' }
        default { throw "Unknown format: $Format" }
    }
}

function Resolve-DataItem([object]$Item, [hashtable]$Context) {
    $label = [string]$Item.label
    try {
        $hasField = $null -ne $Item.field -and [string]$Item.field -ne ''
        $hasExpression = $null -ne $Item.expression -and [string]$Item.expression -ne ''
        if ($hasField -eq $hasExpression) { throw 'Item must specify exactly one field or expression' }
        if ($hasField) {
            $field = [string]$Item.field
            if (($field -notin $script:AllowedEvaluatorFields) -or (-not ($Context.ContainsKey($field)))) { throw "Unknown field: $field" }
            $rawValue = $Context[$field]
        } else { $rawValue = Evaluate-Expression ([string]$Item.expression) $Context }
        $value = Format-DisplayValue $rawValue ([string]$Item.format)
        return [pscustomobject]@{ label = $label; value = $value }
    } catch {
        return [pscustomobject]@{ label = $label; value = '--'; error = $_.Exception.Message }
    }
}
