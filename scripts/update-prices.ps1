$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$CardsPath = Join-Path $RepoRoot "cards.json"
$PricesPath = Join-Path $RepoRoot "prices.json"
$ApiUrl = "https://mp-search-api.tcgplayer.com/v1/search/request"
$PageSize = 50

function Normalize-SetName([string]$Name) {
    $value = $Name.Trim().ToLowerInvariant()
    if ($value -eq "promotional") { return "promo" }
    return $value
}

function Normalize-Finish([string]$Name) {
    $value = $Name.Trim().ToLowerInvariant()
    if ($value -eq "rainbow foil") { return "rainbow" }
    return $value
}

function Get-ProductFinish([string]$Name) {
    $value = $Name.ToLowerInvariant()
    if ($value.Contains("rainbow foil")) { return "rainbow" }
    if ($value.Contains("foil")) { return "foil" }
    return "standard"
}

function Get-NameCandidates([string]$Name) {
    $withoutFinish = ($Name -replace '\s*(rainbow foil|foil)\s*$', '').Trim()
    $withoutParentheses = ($withoutFinish -replace '\s*\([^)]*\)', '').Trim()
    return @(
        $withoutFinish.ToLowerInvariant(),
        $withoutParentheses.ToLowerInvariant()
    ) | Select-Object -Unique
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

Write-Host "Loading canonical card catalogue..."
$cards = Get-Content $CardsPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $cards -or $cards.Count -eq 0) {
    throw "cards.json is missing or invalid."
}

$printingIndex = @{}
foreach ($card in $cards) {
    $name = $card.name.Trim().ToLowerInvariant()
    foreach ($printing in $card.printings) {
        $setName = Normalize-SetName $printing.set.name
        $finish = Normalize-Finish $printing.meta.finish
        $printingIndex["$name|$setName|$finish"] = $printing.slug
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
        $printingIndex["$($entry.Value)|$setName|$finish"] = $entry.Key
    }
}

Write-Host "Fetching TCGPlayer products..."
$headers = @{ Accept = "application/json"; "Content-Type" = "application/json" }
$response = Invoke-RestMethod -Uri $ApiUrl -Method Post -Headers $headers -Body (New-RequestBody 0)
$total = [int]$response.results.totalResults
$products = @($response.results.results)

for ($offset = $PageSize; $offset -lt $total; $offset += $PageSize) {
    Write-Host "Fetching products $offset through $([Math]::Min($offset + $PageSize, $total)) of $total..."
    $response = Invoke-RestMethod -Uri $ApiUrl -Method Post -Headers $headers -Body (New-RequestBody $offset)
    $products += @($response.results.results)
    Start-Sleep -Milliseconds 500
}
if ($products.Count -lt $total) {
    throw "Incomplete TCGPlayer response: expected $total products, received $($products.Count)."
}

$prices = @{}
$unmatched = 0
foreach ($product in $products) {
    $rawName = [string]$product.productName
    $setName = [string]$product.setName
    if (-not $rawName -or -not $setName -or $null -eq $product.marketPrice) { continue }

    $normalizedSet = Normalize-SetName $setName
    $finish = Get-ProductFinish $rawName
    $slug = $null
    foreach ($candidate in (Get-NameCandidates $rawName)) {
        $slug = $printingIndex["$candidate|$normalizedSet|$finish"]
        if ($slug) { break }
    }

    if (-not $slug) {
        $unmatched++
        if ($unmatched -le 20) {
            Write-Warning "Unmatched: $rawName [$setName, $finish]"
        }
        continue
    }
    $prices[$slug] = @{ market = $product.marketPrice; low = $product.lowestPrice }
}

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

        $printingCopy = [ordered]@{}
        foreach ($property in $printing.PSObject.Properties) {
            $printingCopy[$property.Name] = $property.Value
        }
        $printingCopy["price"] = [ordered]@{
            market = $value.market
            low = $value.low
            currency = "USD"
        }
        $pricedPrintings += $printingCopy
    }

    if ($pricedPrintings.Count -eq 0) { continue }

    $cardCopy = [ordered]@{}
    foreach ($property in $card.PSObject.Properties) {
        if ($property.Name -ne "printings") {
            $cardCopy[$property.Name] = $property.Value
        }
    }
    $cardCopy["printings"] = $pricedPrintings
    $pricedCards += $cardCopy
}

$json = ($pricedCards | ConvertTo-Json -Depth 12) + [Environment]::NewLine
[IO.File]::WriteAllText($PricesPath, $json, (New-Object Text.UTF8Encoding $false))
Write-Host "Published $($prices.Count) priced printings across $($pricedCards.Count) cards; $unmatched products unmatched."
