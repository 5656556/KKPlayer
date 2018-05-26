//
//  ViewController.m
//  demo-ios
//
//  Created by KKFinger on 2017/3/15.
//  Copyright © 2017年 KKFinger. All rights reserved.
//

#import "ViewController.h"
#import "PlayerViewController.h"

@implementation ViewController

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{
    return 2;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath{
    UITableViewCell * cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if(indexPath.row == 0){
        cell.textLabel.text = @"The Three Diablos";
    }else{
        cell.textLabel.text = @"goole help vr";
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath{
    PlayerViewController * obj = [[PlayerViewController alloc] init];
    [self.navigationController pushViewController:obj animated:YES];
}

- (void)viewWillDisappear:(BOOL)animated{
    [super viewWillDisappear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:YES];
}

- (void)viewWillAppear:(BOOL)animated{
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:YES];
}

@end
