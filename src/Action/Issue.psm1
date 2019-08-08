Join-Path $PSScriptRoot '..\Helpers.psm1' | Import-Module

function Test-Hash {
    param (
        [Parameter(Mandatory = $true)]
        [String] $Manifest,
        [Int] $IssueID
    )

    $gci, $man = Get-Manifest $Manifest

    $outputH = @(& (Join-Path $BINARIES_FOLDER 'checkhashes.ps1') -App $gci.Basename -Dir $MANIFESTS_LOCATION -Force *>&1)
    Write-Log 'Output' $outputH

    if (($outputH[-2] -like 'OK') -and ($outputH[-1] -like 'Writing*')) {
        Write-Log 'Cannot reproduce'

        Add-Comment -ID $IssueID -Message @(
            'Cannot reproduce',
            '',
            "Are you sure your scoop is up to date? Please run ``scoop update; scoop uninstall $Manifest; scoop install $Manifest``"
        )
        Remove-Label -ID $IssueID -Label 'hash-fix-needed'
        Close-Issue -ID $IssueID
    } elseif ($outputH[-1] -notlike 'Writing*') {
        # There is some error
        Write-Log 'Automatic check of hashes encounter some problems.'

        Add-Label -Id $IssueID -Label 'package-fix-needed'
    } else {
        Write-Log 'Verified hash failed'

        Add-Label -ID $IssueID -Label 'verified', 'hash-fix-needed'
        $message = @('You are right. Thanks for reporting.')
        $prs = (Invoke-GithubRequest "repos/$REPOSITORY/pulls?state=open&base=master&sorting=updated").Content | ConvertFrom-Json
        $prs = $prs | Where-Object { $_.title -ceq "$Manifest@$($man.version): Hash fix" }

        # There is alreay PR for
        if ($prs.Count -gt 0) {
            Write-Log 'PR - Update description'

            # Only take latest updated
            $pr = $prs | Select-Object  -First 1
            $prID = $pr.number
            $prBody = $pr.Body
            # TODO: Additional checks if this PR is really fixing same issue

            $message += ''
            $message += "There is already pull request to fix this issue. (#$prID)"

            Write-Log 'PR ID' $prID
            # Update PR description
            Invoke-GithubRequest "repos/$REPOSITORY/pulls/$prID" -Method Patch -Body @{ "body" = (@("- Closes #$IssueID", $prBody) -join "`r`n") }
        } else {
            Write-Log 'PR - Create new branch and post PR'

            $branch = "$Manifest-hash-fix-$(Get-Random -Maximum 258258258)"
            hub checkout -B $branch

            Write-Log 'Git Status' @(hub status --porcelain)

            hub add $gci.FullName
            hub commit -m "${Manifest}: hash fix"
            hub push origin $branch

            # Create new PR
            Invoke-GithubRequest -Query "repos/$REPOSITORY/pulls" -Method Post -Body @{
                'title' = "$Manifest@$($man.version): Hash fix"
                'base'  = 'master'
                'head'  = $branch
                'body'  = "- Closes #$IssueID"
            }
        }
        Add-Comment -ID $IssueID -Message $message
    }
}

function Test-Downloading {
    param([String] $Manifest, [Int] $IssueID)

    $manifest_path = Get-Childitem $MANIFESTS_LOCATION "$Manifest.*" | Select-Object -First 1 -ExpandProperty Fullname
    $manifest_o = Get-Content $manifest_path -Raw | ConvertFrom-Json

    $broken_urls = @()
    # TODO: Aria2 support
    # dl_with_cache_aria2 $Manifest 'DL' $manifest_o (default_architecture) "/" $manifest_o.cookies $true

    # exit 0
    foreach ($arch in @('64bit', '32bit')) {
        $urls = @(url $manifest_o $arch)

        foreach ($url in $urls) {
            Write-Log 'url' $url

            try {
                dl_with_cache $Manifest 'DL' $url $null $manifest_o.cookies $true
            } catch {
                $broken_urls += $url
                continue
            }
        }
    }

    if ($broken_urls.Count -eq 0) {
        Write-Log 'All OK'

        $message = @(
            'Cannot reproduce.',
            '',
            'All files can be downloaded properly (Please keep in mind I can only download files without aria2 support (yet))',
            'Downloading problems could be caused by:'
            '',
            '- Proxy configuration',
            '- Network error',
            '- Site is blocked (Great Firewall of China, Corporate restrictions, ...)'
        )

        Add-Comment -ID $IssueID -Comment $message
        # TODO: Close??
    } else {
        Write-Log 'Broken URLS' $broken_urls

        $string = ($broken_urls | ForEach-Object { "- $_" }) -join "`r`n"
        Add-Label -ID $IssueID -Label 'package-fix-needed', 'verified', 'help-wanted'
        Add-Comment -ID $IssueID -Comment 'Thanks for reporting. You are right. Following URLs are not accessible:', '', $string
    }
}

function Initialize-Issue {
    Write-Log 'Issue initialized'

    if ($EVENT.action -ne 'opened') {
        Write-Log "Only action 'opened' is supported"
        exit 0
    }

    $title = $EVENT.issue.title
    $id = $EVENT.issue.number

    $problematicName, $problematicVersion, $problem = Resolve-IssueTitle $title
    if (($null -eq $problematicName) -or
        ($null -eq $problematicVersion) -or
        ($null -eq $problem)
    ) {
        Write-Log 'Not compatible issue title'
        exit 0
    }

    $null, $manifest_loaded = Get-Manifest $problematicName
    if ($manifest_loaded.version -ne $problematicVersion) {
        Add-Comment -ID $id -Message @("You reported version ``$problematicVersion``, but latest available version is ``$($manifest_loaded.version)``.", "", "Run ``scoop update; scoop uninstall $problematicName; scoop install $problematicName``")
        Close-Issue -ID $id
        exit 0
    }

    switch -Wildcard ($problem) {
        '*hash check*' {
            Write-Log 'Hash check failed'
            Test-Hash $problematicName $id
        }
        '*extract_dir*' {
            Write-Log 'Extract dir error'
            # TODO:
            # Test-ExtractDir $problematicName $id
        }
        '*download*failed*' {
            Write-Log 'Download failed'
            Test-Downloading $problematicName $id
        }
    }

    Write-Log 'Issue finished'
}

Export-ModuleMember -Function Initialize-Issue