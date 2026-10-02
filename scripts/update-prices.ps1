$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$CardsPath = Join-Path $RepoRoot "cards.json"
$PricesPath = Join-Path $RepoRoot "prices.json"
$ReportPath = Join-Path $RepoRoot "price-match-report.json"
$ApiUrl = "https://mp-search-api.tcgplayer.com/v1/search/request"
$PageSize = 50

# Use the same comparison form on both sources; keep original display names.
function Normalize-CardName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return "" }
    $builder = New-Object Text.StringBuilder
    foreach ($character in $Name.Normalize([Text.NormalizationForm]::FormD).ToCharArray()) {
        $category = [Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($category -notin @(
            [Globalization.UnicodeCategory]::NonSpacingMark,
            [Globalization.UnicodeCategory]::SpacingCombiningMark,
            [Globalization.UnicodeCategory]::EnclosingMark
        )) { [void]$builder.Append($character) }
    }
    return (($builder.ToString().Normalize([Text.NormalizationForm]::FormC) -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function Normalize-SetName([string]$Name) {
    $value = Normalize-CardName $Name
    if ($value -eq "promotional") { return "promo" }
    return $value
}

function Normalize-Finish([string]$Name) {
    $value = Normalize-CardName $Name
    if ($value -eq "rainbow foil") { return "rainbow" }
    return $value
}

function Get-ProductFinish([string]$Name) {
    if ($Name -match '\(rainbow foil\)|\s+rainbow foil\s*$') { return "rainbow" }
    if ($Name -match '\(foil\)|\s+foil\s*$') { return "foil" }
    return "standard"
}

function Get-NameCandidates([string]$Name) {
    $value = ($Name -replace '\s*\((?:rainbow foil|foil)\)', '')
    $value = ($value -replace '\s+(?:rainbow foil|foil)\s*$', '').Trim()
    # Keep artwork qualifiers first so explicit token aliases take precedence.
    $withoutProduct = ($value -replace '\s*\(box topper\)', '').Trim()
    $numberedToken = $withoutProduct -replace '^Foot Soldier \(([123])\)$', 'Foot Soldier $1'
    $withoutParentheses = ($value -replace '\s*\([^)]*\)', '').Trim()
    return @(Normalize-CardName $value; Normalize-CardName $withoutProduct; Normalize-CardName $numberedToken; Normalize-CardName $withoutParentheses) |
        Where-Object { $_ } | Select-Object -Unique
}

function Add-PrintingKey([string]$Key, [string]$Slug) {
    # Never silently overwrite different printings with the same comparison key.
    $printingIndex[$Key] = @(@($printingIndex[$Key]) + $Slug |
        Where-Object { $_ } | Select-Object -Unique)
}

function New-RequestBody([int]$Offset) {
    return @{
        algorithm = "sales_synonym_v2"
        from = $Offset
        size = $PageSize
        filters = @{ term = @{ productLineName = @("Sorcery Contested Realm") } }
        listingSearch = @{ filters = @{ range = @{ quantity = @{ gte = 1 } } } }
        context = @{ shippingCountry = "US" }
    } | ConvertTo-Json -Depth 10
}

function Invoke-TcgRequest([int]$Offset) {
    $maximumAttempts = 5
    $retryDelays = @(10, 30, 60, 120)

    for ($attempt = 1; $attempt -le $maximumAttempts; $attempt++) {
        try {
            return Invoke-RestMethod `
                -Uri $ApiUrl `
                -Method Post `
                -Headers $headers `
                -Body (New-RequestBody $Offset) `
                -TimeoutSec 60
        }
        catch {
            $statusCode = $null
            if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            $transient = (
                $null -eq $statusCode -or
                $statusCode -eq 429 -or
                $statusCode -ge 500
            )

            if (-not $transient -or $attempt -eq $maximumAttempts) {
                throw
            }

            $delay = $retryDelays[$attempt - 1]
            $statusText = if ($null -eq $statusCode) { "network error" } else { "HTTP $statusCode" }
            Write-Warning "$statusText at offset $Offset. Attempt $attempt of $maximumAttempts failed; retrying in $delay seconds."
            Start-Sleep -Seconds $delay
        }
    }
}

Write-Host "Loading canonical card catalogue..."
$cards = Get-Content $CardsPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $cards -or $cards.Count -eq 0) {
    throw "cards.json is missing or invalid."
}

$printingIndex = @{}
$nameIndex = @{}
$printingBySlug = @{}
foreach ($card in $cards) {
    $name = Normalize-CardName $card.name
    foreach ($printing in $card.printings) {
        $setName = Normalize-SetName $printing.set.name
        $finish = Normalize-Finish $printing.meta.finish
        Add-PrintingKey "$name|$setName|$finish" $printing.slug
        $printingBySlug[$printing.slug] = $printing
        $nameIndex[$name] = @(@($nameIndex[$name]) + $printing.slug | Where-Object { $_ } | Select-Object -Unique)
    }
}

# The official catalogue groups these token artworks under one card name,
# while TCGPlayer exposes some variants as separately named products.
$tokenAliases = @{
    "004-foot_soldier-bt-s" = "foot soldiers"
    "001-foot_soldier_1-bt-s" = "foot soldier 1"
    "001-foot_soldier_2-bt-s" = "foot soldier 2"
    "001-foot_soldier_3-bt-s" = "foot soldier 3"
    "002-foot_soldier_1-bt-s" = "foot soldier 1"
    "002-foot_soldier_2-bt-s" = "foot soldier 2"
    "002-foot_soldier_3-bt-s" = "foot soldier 3"
    "999-foot_soldier_english-d-s" = "foot soldier (english)"
    "999-foot_soldier_saracen-d-s" = "foot soldier (saracen)"
    "001-frog_blue-bt-s" = "frog (blue)"
    "001-frog_green-bt-s" = "frog (green)"
    "001-frog_red-bt-s" = "frog (red)"
    "002-frog_blue-bt-s" = "frog (blue)"
    "002-frog_green-bt-s" = "frog (green)"
    "002-frog_red-bt-s" = "frog (red)"
}
foreach ($entry in $tokenAliases.GetEnumerator()) {
    $printing = $cards.printings | Where-Object { $_.slug -eq $entry.Key } | Select-Object -First 1
    if ($printing) {
        $setName = Normalize-SetName $printing.set.name
        $finish = Normalize-Finish $printing.meta.finish
        Add-PrintingKey "$(Normalize-CardName $entry.Value)|$setName|$finish" $entry.Key
        $aliasName = Normalize-CardName $entry.Value
        $nameIndex[$aliasName] = @(@($nameIndex[$aliasName]) + $entry.Key | Where-Object { $_ } | Select-Object -Unique)
    }
}

function Resolve-Product([string]$Name, [string]$SetName, [string]$Finish) {
    $type = $null
    $promo = $false
    $explicitFinish = $Name -match '\((?:rainbow foil|foil)\)|\s+(?:rainbow foil|foil)\s*$'
    if ($Name -match 'box topper') { $type = "BoxTopper" }
    elseif ($Name -match 'draft kit') { $type = "DraftKit"; $promo = $true }
    elseif ($Name -match 'pledge pack') { $type = "Kickstarter"; $promo = $true }
    elseif ($Name -match 'alpha investments?') { $type = "AlphaInvestments"; $promo = $true }
    elseif ($Name -match 'team covenant') { $type = "TeamCovenant"; $promo = $true }
    elseif ($Name -match 'star city|scgcon') { $type = "StarCityGames"; $promo = $true }
    elseif ($Name -match 'store.*promo') { $type = "OrganizedPlay"; $promo = $true }
    elseif ($SetName -eq 'dust reward promos') { $type = "Dust"; $promo = $true }
    elseif ($SetName -eq 'welcome kit promos') { $type = "WelcomeKit"; $promo = $true }
    elseif ($Name -match 'preconstructed') { $type = "PreconstructedDeck" }

    # Unknown qualifiers may represent distinct art, misprints, or promo editions.
    # Do not erase them and accidentally use an ordinary booster price.
    $remaining = $Name -replace '\((?:rainbow foil|foil|box topper|draft kit|pledge pack|alpha investments? promo|team covenant(?: promo)?|star city game(?:s)? promo|scgcon promo|store[^)]*promo|corrected)\)', ''
    $unsupported = $remaining -match '\([^)]*\)' -and -not $type
    $all = @()
    foreach ($candidate in (Get-NameCandidates $Name)) {
        $found = @($nameIndex[$candidate] | Where-Object { $_ })
        if ($found.Count -gt 0) { $all = $found; break }
    }
    if ($all.Count -eq 0) { return @{ reason = "name-mismatch"; slugs = @() } }
    if ($unsupported) { return @{ reason = "unsupported-product-qualifier"; slugs = $all } }
    if ($promo) { $SetName = "promo" }
    $setMatches = @($all | Where-Object { (Normalize-SetName $printingBySlug[$_].set.name) -eq $SetName })
    if ($setMatches.Count -eq 0) { return @{ reason = "set-mismatch"; slugs = $all } }
    if ($type) {
        $setMatches = @($setMatches | Where-Object { $printingBySlug[$_].meta.product -eq $type })
    } else {
        # Unqualified main-set products refer to booster printings when available.
        $boosters = @($setMatches | Where-Object { $printingBySlug[$_].meta.product -eq "Booster" })
        if ($boosters.Count -gt 0) { $setMatches = $boosters }
    }
    if ($setMatches.Count -eq 0) { return @{ reason = "product-type-mismatch"; slugs = $all } }
    $finished = @($setMatches | Where-Object { (Normalize-Finish $printingBySlug[$_].meta.finish) -eq $Finish })
    # Some promo listings omit Foil; infer it only when one printing remains.
    if ($finished.Count -eq 0 -and $promo -and -not $explicitFinish -and $setMatches.Count -eq 1) { $finished = $setMatches }
    if ($finished.Count -eq 0) { return @{ reason = "finish-mismatch"; slugs = $setMatches } }
    if ($finished.Count -gt 1) { return @{ reason = "ambiguous-canonical-match"; slugs = $finished } }
    return @{ reason = "resolved"; slugs = $finished; slug = $finished[0] }
}

Write-Host "Fetching TCGPlayer products..."
$headers = @{ Accept = "application/json"; "Content-Type" = "application/json" }
$response = Invoke-TcgRequest 0
$total = [int]$response.results.totalResults
$products = @($response.results.results)

for ($offset = $PageSize; $offset -lt $total; $offset += $PageSize) {
    Write-Host "Fetching products $offset through $([Math]::Min($offset + $PageSize, $total)) of $total..."
    $response = Invoke-TcgRequest $offset
    $products += @($response.results.results)
    Start-Sleep -Milliseconds 500
}
if ($products.Count -lt $total) {
    throw "Incomplete TCGPlayer response: expected $total products, received $($products.Count)."
}

$prices = @{}
$productReport = New-Object 'System.Collections.Generic.List[object]'
$seenSlugs = @{}
$unmatched = 0
$seenProductIds = @{}
foreach ($product in $products) {
    $rawName = [string]$product.productName
    $setName = [string]$product.setName
    $normalizedSet = Normalize-SetName $setName
    $finish = Get-ProductFinish $rawName
    $candidates = @(Get-NameCandidates $rawName)
    $slug = $null
    $possibleSlugs = @()
    $reason = $null

    $productKey = [string]$product.productId
    if ($productKey -and $seenProductIds.ContainsKey($productKey)) {
        $reason = "repeated-product-id"
    } elseif (-not $rawName -or -not $setName) {
        $reason = "missing-product-fields"
    } elseif ($rawName -match '(?i)\bbooster (?:box|pack|case)\b|\bpreconstructed deck(?:s| box)?\b|^Dragonlord Box$|^Sorcery: Contested Realm - Pledge Pack$') {
        $reason = "non-card-product"
    } else {
        $resolution = Resolve-Product $rawName $normalizedSet $finish
        $possibleSlugs = @($resolution.slugs)
        $slug = $resolution.slug
        if (-not $slug) { $reason = $resolution.reason }
        if ($slug) {
            if (-not $seenSlugs.ContainsKey($slug)) { $seenSlugs[$slug] = @() }
            $seenSlugs[$slug] += $product.productId
            $market = 0.0
            $validPrice = $null -ne $product.marketPrice -and
                [double]::TryParse([string]$product.marketPrice,
                    [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref]$market) -and
                -not [double]::IsNaN($market) -and -not [double]::IsInfinity($market) -and $market -ge 0
            if (-not $validPrice) {
                $reason = "missing-or-invalid-market-price"
            } elseif ($prices.ContainsKey($slug)) {
                # Keep the first price consistently; expose duplicate products for review.
                $reason = "duplicate-priced-printing"
            } else {
                $prices[$slug] = @{ market = $market; low = $product.lowestPrice }
                $reason = "matched"
            }
        }
    }
    if ($productKey -and $reason -ne "repeated-product-id") { $seenProductIds[$productKey] = $true }
    $productReport.Add([ordered]@{
        productId = $product.productId; productName = $rawName; setName = $setName
        finish = $finish; marketPrice = $product.marketPrice; lowestPrice = $product.lowestPrice
        reason = $reason; matchedSlug = $slug; candidateNames = $candidates
        possibleCanonicalSlugs = $possibleSlugs
    })
    if ($reason -notin @("matched", "non-card-product", "repeated-product-id")) {
        $unmatched++
        # Full details for every product are retained in the JSON report.
        if ($unmatched -le 20 -or $rawName -match '^Band of Thieves(?:\s|$)') {
            Write-Warning "${reason}: $rawName [$setName, $finish]"
        }
    }
}

$missingPrintings = @(
    foreach ($card in $cards) {
        foreach ($printing in $card.printings) {
            if (-not $prices.ContainsKey($printing.slug)) {
                [ordered]@{
                    cardName = $card.name; cardSlug = $card.slug; printingSlug = $printing.slug
                    setName = $printing.set.name; finish = $printing.meta.finish
                    reason = $(if ($seenSlugs.ContainsKey($printing.slug)) { "matched-product-without-valid-price" } else { "no-matched-product" })
                    productIds = @($seenSlugs[$printing.slug] | Where-Object { $null -ne $_ })
                }
            }
        }
    }
)
$summary = [ordered]@{ productsFetched = $products.Count; uniqueProductIds = $seenProductIds.Count; pricedPrintings = $prices.Count; canonicalPrintingsWithoutPrice = $missingPrintings.Count }
# Dictionary entries require key lookup rather than property grouping in Windows PowerShell.
foreach ($entry in $productReport) {
    $reasonKey = [string]$entry["reason"]
    if (-not $summary.Contains($reasonKey)) { $summary[$reasonKey] = 0 }
    $summary[$reasonKey]++
}
foreach ($reasonKey in @($summary.Keys)) {
    Write-Host "${reasonKey}: $($summary[$reasonKey])"
}
if ($summary.Contains("repeated-product-id")) {
    Write-Warning "Pagination returned $($summary['repeated-product-id']) repeated product IDs. $($seenProductIds.Count) unique IDs were received; repeated rows do not prove complete catalogue coverage."
}
$report = [ordered]@{
    schemaVersion = 1; generatedAt = [DateTime]::UtcNow.ToString("o")
    summary = $summary; products = @($productReport.ToArray()); canonicalPrintingsWithoutPrice = $missingPrintings
}
[IO.File]::WriteAllText($ReportPath, (($report | ConvertTo-Json -Depth 12) + [Environment]::NewLine), (New-Object Text.UTF8Encoding $false))
Write-Host "Canonical printings without price: $($missingPrintings.Count). Full diagnostics: $ReportPath"

if ($prices.Count -eq 0) { throw "No prices were matched." }
if (Test-Path $PricesPath) {
    $previous = Get-Content $PricesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $previousCount = @(
        $previous |
            ForEach-Object { $_.printings } |
            ForEach-Object { $_ }
    ).Count
    if ($previousCount -gt 0) {
        $minimum = [Math]::Max(500, [Math]::Floor($previousCount * 0.80))
        if ($prices.Count -lt $minimum) {
            throw "Suspicious price-count reduction: $previousCount -> $($prices.Count)."
        }
    }
}

$pricedCards = @()
foreach ($card in $cards) {
    $pricedPrintings = @()
    foreach ($printing in $card.printings) {
        $value = $prices[$printing.slug]
        if (-not $value) { continue }

        $printingCopy = [ordered]@{
            id = $printing.id
            slug = $printing.slug
            set = [ordered]@{
                name = $printing.set.name
                code = $printing.set.code
            }
            meta = [ordered]@{
                finish = $printing.meta.finish
            }
            price = [ordered]@{
                market = $value.market
                low = $value.low
                currency = "USD"
            }
        }
        $pricedPrintings += $printingCopy
    }

    if ($pricedPrintings.Count -eq 0) { continue }

    $cardCopy = [ordered]@{
        id = $card.id
        name = $card.name
        slug = $card.slug
        printings = $pricedPrintings
    }
    $pricedCards += $cardCopy
}

$json = (ConvertTo-Json -InputObject @($pricedCards) -Depth 12 -Compress) + [Environment]::NewLine
[IO.File]::WriteAllText($PricesPath, $json, (New-Object Text.UTF8Encoding $false))
Write-Host "Published $($prices.Count) priced printings across $($pricedCards.Count) cards; $unmatched products unmatched."
